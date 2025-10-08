// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"runtime/trace"
	"time"

	traceexp "golang.org/x/exp/trace"

	"bchess.org/dist-scheduler/pkg/distpermit"
	"bchess.org/dist-scheduler/pkg/podservice"
	"bchess.org/dist-scheduler/pkg/schedulerset"
	"bchess.org/dist-scheduler/pkg/util"
	"bchess.org/dist-scheduler/pkg/webhook"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"google.golang.org/grpc/encoding"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilerrors "k8s.io/apimachinery/pkg/util/errors"
	apiserver "k8s.io/apiserver/pkg/server"
	"k8s.io/apiserver/pkg/server/healthz"
	utilversion "k8s.io/apiserver/pkg/util/version"
	"k8s.io/client-go/informers"
	coreinformers "k8s.io/client-go/informers/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/events"
	cliflag "k8s.io/component-base/cli/flag"
	"k8s.io/component-base/cli/globalflag"
	"k8s.io/component-base/logs"
	logsapi "k8s.io/component-base/logs/api/v1"
	"k8s.io/component-base/term"
	"k8s.io/component-base/version/verflag"
	"k8s.io/klog/v2"
	"k8s.io/kubernetes/cmd/kube-scheduler/app"
	schedulerserverconfig "k8s.io/kubernetes/cmd/kube-scheduler/app/config"
	"k8s.io/kubernetes/cmd/kube-scheduler/app/options"
	"k8s.io/kubernetes/pkg/scheduler"
	kubeschedulerconfig "k8s.io/kubernetes/pkg/scheduler/apis/config"
	"k8s.io/kubernetes/pkg/scheduler/apis/config/latest"
	"k8s.io/kubernetes/pkg/scheduler/framework"
	frameworkruntime "k8s.io/kubernetes/pkg/scheduler/framework/runtime"
	"k8s.io/kubernetes/pkg/scheduler/profile"
)

const SchedulerGroupLabelKey = "dist-scheduler.dev/scheduler"
const PodQueueSize = 1000000
const NumSchedulers = 100
const DefaultNumConcurrentSchedulers = 8

func NewSchedulerCommand() *cobra.Command {
	opts := options.NewOptions()

	cmd := &cobra.Command{
		Use:   "dist-scheduler",
		Short: "Distributed Scheduler using kubernetes scheduler logic",
		PersistentPreRunE: func(*cobra.Command, []string) error {
			// makes sure feature gates are set before RunE.
			return opts.ComponentGlobalsRegistry.Set()
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			return Run(cmd, opts)
		},
	}

	nfs := opts.Flags
	verflag.AddFlags(nfs.FlagSet("global"))
	globalflag.AddGlobalFlags(nfs.FlagSet("global"), cmd.Name(), logs.SkipLoggingConfigurationFlags())
	fs := cmd.Flags()

	myFs := pflag.NewFlagSet("Dist Scheduler", pflag.ExitOnError)
	myFs.String("grpc-addr", ":50051", "gRPC server address")
	myFs.String("node-selector", "", "Scheduler only tracks nodes with this label selector. (Only applies for leader)")
	myFs.Int("num-concurrent-schedulers", DefaultNumConcurrentSchedulers, "number of concurrent schedulers")
	myFs.Float64("wait-for-subschedulers", 1.0, "wait for sub-schedulers to finish before proceeding")
	myFs.Bool("leader-eligible", true, "Whether this scheduler should run for leader election")
	myFs.Bool("permit-always-deny", false, "Have Permit deny all pods. For testing only")
	myFs.Bool("relay-only", false, "Only relay pods, do not schedule ourselves")
	myFs.Bool("watch-pods", false, "Leader watches for unscheduled pods (otherwise just use admission hook)")

	nfs.FlagSets["Dist Scheduler"] = myFs

	nfs.Order = append(nfs.Order, "Dist Scheduler")

	for _, f := range nfs.FlagSets {
		fs.AddFlagSet(f)
	}

	cols, _, _ := term.TerminalSize(cmd.OutOrStdout())
	cliflag.SetUsageAndHelpFunc(cmd, *nfs, cols)

	if err := cmd.MarkFlagFilename("config", "yaml", "yml", "json"); err != nil {
		klog.Background().Error(err, "Failed to mark flag filename")
	}

	return cmd
}

func Run(cmd *cobra.Command, opts *options.Options) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		stopCh := apiserver.SetupSignalHandler()
		<-stopCh
		cancel()
	}()

	distScheduler, err := Start(ctx, opts)
	if err != nil {
		log.Fatalf("Failed to setup scheduler: %v", err)
	}
	distScheduler.Run(ctx)

	return nil
}

func Start(ctx context.Context, opts *options.Options, outOfTreeRegistryOptions ...app.Option) (*DistScheduler, error) {
	fg := opts.ComponentGlobalsRegistry.FeatureGateFor(utilversion.DefaultKubeComponent)
	if err := logsapi.ValidateAndApply(opts.Logs, fg); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}

	if cfg, err := latest.Default(); err != nil {
		return nil, err
	} else {
		opts.ComponentConfig = cfg
	}
	dsFlags := opts.Flags.FlagSet("Dist Scheduler")

	if errs := opts.Validate(); len(errs) > 0 {
		return nil, utilerrors.NewAggregate(errs)
	}

	c, err := opts.Config(ctx)
	if err != nil {
		return nil, err
	}

	registerMetrics()

	// Start caching the endpoint slices for the dist-scheduler service
	namespace := os.Getenv("POD_NAMESPACE")
	if namespace == "" {
		return nil, fmt.Errorf("POD_NAMESPACE is not set")
	}
	podName := os.Getenv("POD_NAME")
	if podName == "" {
		return nil, fmt.Errorf("POD_NAME is not set")
	}
	allowSolo := os.Getenv("ALLOW_SOLO") == "true"
	schedulerSet, err := schedulerset.NewSchedulerSet(ctx, c.Client, namespace, podName, 10, allowSolo)
	if err != nil {
		return nil, err
	}

	nodeSelector := dsFlags.Lookup("node-selector").Value.String()

	grpcAddr := dsFlags.Lookup("grpc-addr").Value.String()
	podQueue := make(chan *v1.Pod, PodQueueSize)
	distScheduler, err := SetupScheduler(ctx, podName, podQueue, schedulerSet, opts, c, outOfTreeRegistryOptions...)
	if err != nil {
		return nil, err
	}
	StartGrpcServer(ctx, grpcAddr, schedulerSet, distScheduler)

	// Start the webhook server
	webhookAddr := ":8443"
	distScheduler.webhookServer = webhook.NewWebhookServer(webhookAddr, podQueue)
	go func() {
		if err := distScheduler.webhookServer.Start(); err != nil {
			klog.Error(err, "Failed to start webhook server")
		}
	}()

	leaderEligible, err := dsFlags.GetBool("leader-eligible")
	if err != nil {
		return nil, fmt.Errorf("failed to convert leader-eligible to bool: %v", err)
	}
	if leaderEligible {
		watchPods, err := dsFlags.GetBool("watch-pods")
		if err != nil {
			return nil, fmt.Errorf("failed to convert watch-pods to bool: %v", err)
		}
		StartLeaderActivities(ctx, podName, namespace, podQueue, c.Client, schedulerSet, watchPods, nodeSelector)
	}

	return distScheduler, nil
}

func SetupScheduler(ctx context.Context, podName string, podQueue chan *v1.Pod, schedulerSet *schedulerset.SchedulerSet, opts *options.Options, c *schedulerserverconfig.Config, outOfTreeRegistryOptions ...app.Option) (*DistScheduler, error) {
	c.InformerFactory = informers.NewSharedInformerFactory(c.Client, 0)
	c.InformerFactory.InformerFor(&v1.Node{}, func(cs kubernetes.Interface, resyncPeriod time.Duration) cache.SharedIndexInformer {
		labelSelector := fmt.Sprintf("%s=%s", SchedulerGroupLabelKey, podName)
		tweakListOptions := func(options *metav1.ListOptions) {
			options.LabelSelector = labelSelector
		}
		informer := coreinformers.NewFilteredNodeInformer(c.Client, resyncPeriod, cache.Indexers{}, tweakListOptions)

		// Dropping `.metadata.managedFields` to improve memory usage.
		trim := func(obj interface{}) (interface{}, error) {
			if accessor, err := meta.Accessor(obj); err == nil {
				if accessor.GetManagedFields() != nil {
					accessor.SetManagedFields(nil)
				}
			}
			return obj, nil
		}
		informer.SetTransform(trim)
		return informer
	})
	c.InformerFactory.InformerFor(&v1.Pod{}, func(cs kubernetes.Interface, resyncPeriod time.Duration) cache.SharedIndexInformer {
		// Effectively disable the pod informer
		// TODO: make this work without a real watcher
		tweakListOptions := func(options *metav1.ListOptions) {
			options.LabelSelector = "dist-scheduler.dev/bogus=bogus"
		}
		informer := coreinformers.NewFilteredPodInformer(c.Client, "fakenamespace", resyncPeriod, cache.Indexers{}, tweakListOptions)
		return informer
	})

	cc := c.Complete()
	dsFlags := opts.Flags.FlagSet("Dist Scheduler")

	// Start up the healthz server.
	if cc.SecureServing != nil {
		isLeader := func() bool {
			return true
		}
		noChecks := []healthz.HealthChecker{}
		handler := buildHandlerChain(newHealthEndpointsAndMetricsHandler(&cc.ComponentConfig, cc.InformerFactory, isLeader, noChecks, noChecks), cc.Authentication.Authenticator, cc.Authorization.Authorizer)
		// TODO: handle stoppedCh and listenerStoppedCh returned by c.SecureServing.Serve
		if _, _, err := cc.SecureServing.Serve(handler, 0, ctx.Done()); err != nil {
			// fail early for secure handlers, removing the old error loop from above
			return nil, fmt.Errorf("failed to start secure server: %v", err)
		}
	}

	alwaysDeny, err := dsFlags.GetBool("permit-always-deny")
	if err != nil {
		return nil, fmt.Errorf("failed to convert permit-always-deny to bool: %v", err)
	}

	numConcurrentSchedulers, err := dsFlags.GetInt("num-concurrent-schedulers")
	if err != nil {
		return nil, fmt.Errorf("failed to convert num-concurrent-schedulers to int: %v", err)
	}
	relayOnly, err := dsFlags.GetBool("relay-only")
	if err != nil {
		return nil, fmt.Errorf("failed to convert relay-only to bool: %v", err)
	}
	outOfTreeRegistryOptions = append(outOfTreeRegistryOptions, func(registry frameworkruntime.Registry) error {
		registry["DistPermit"] = func(ctx context.Context, obj runtime.Object, handle framework.Handle) (framework.Plugin, error) {
			return distpermit.New(ctx, obj, handle, schedulerSet, alwaysDeny)
		}
		return nil
	})

	outOfTreeRegistry := make(frameworkruntime.Registry)
	for _, option := range outOfTreeRegistryOptions {
		if err := option(outOfTreeRegistry); err != nil {
			return nil, err
		}
	}

	recorderFactory := getRecorderFactory(&cc)
	completedProfiles := make([]kubeschedulerconfig.KubeSchedulerProfile, 0)
	// Create the scheduler.
	var kube_scheds []*scheduler.Scheduler
	if relayOnly {
		kube_scheds = []*scheduler.Scheduler{}
	} else {
		kube_scheds, err = scheduler.NewN(NumSchedulers, ctx,
			cc.Client,
			cc.InformerFactory,
			cc.DynInformerFactory,
			recorderFactory,
			scheduler.WithComponentConfigVersion(cc.ComponentConfig.TypeMeta.APIVersion),
			scheduler.WithKubeConfig(cc.KubeConfig),
			scheduler.WithProfiles(cc.ComponentConfig.Profiles...),
			scheduler.WithPercentageOfNodesToScore(cc.ComponentConfig.PercentageOfNodesToScore),
			scheduler.WithFrameworkOutOfTreeRegistry(outOfTreeRegistry),
			scheduler.WithPodMaxBackoffSeconds(cc.ComponentConfig.PodMaxBackoffSeconds),
			scheduler.WithPodInitialBackoffSeconds(cc.ComponentConfig.PodInitialBackoffSeconds),
			scheduler.WithPodMaxInUnschedulablePodsDuration(cc.PodMaxInUnschedulablePodsDuration),
			scheduler.WithExtenders(cc.ComponentConfig.Extenders...),
			scheduler.WithParallelism(cc.ComponentConfig.Parallelism),
			scheduler.WithBuildFrameworkCapturer(func(profile kubeschedulerconfig.KubeSchedulerProfile) {
				// Profiles are processed during Framework instantiation to set default plugins and configurations. Capturing them for logging
				completedProfiles = append(completedProfiles, profile)
			}),
		)
		if err != nil {
			return nil, err
		}
		cc.InformerFactory.Start(ctx.Done())
		cc.InformerFactory.WaitForCacheSync(ctx.Done())
		go runNodeCountMetric(ctx, kube_scheds[0])
		kube_scheds[0].FailureHandler = func(ctx context.Context, fwk framework.Framework, podInfo *framework.QueuedPodInfo, status *framework.Status, nominatingInfo *framework.NominatingInfo, start time.Time) {
			podScheduleFailure(ctx, podInfo, status, schedulerSet)
		}
	}

	scheds := make([]*Scheduler, len(kube_scheds))
	for i, kube_sched := range kube_scheds {
		sched := &Scheduler{
			scheduler: kube_sched,
			nextPod:   nil,
		}
		kube_sched.FailureHandler = kube_scheds[0].FailureHandler
		scheds[i] = sched
		kube_sched.NextPod = sched.NextPod
	}
	if err := options.LogOrWriteConfig(klog.FromContext(ctx), opts.WriteConfigTo, &cc.ComponentConfig, completedProfiles); err != nil {
		return nil, err
	}

	waitForSubSchedulers, err := dsFlags.GetFloat64("wait-for-subschedulers")
	if err != nil {
		return nil, fmt.Errorf("failed to convert wait-for-subschedulers to float64: %v", err)
	}

	parallelismGauge.Set(float64(cc.ComponentConfig.Parallelism))
	numSchedulersGauge.Set(float64(numConcurrentSchedulers))
	flightRecorder := traceexp.NewFlightRecorder()

	return &DistScheduler{
		schedulerStack:          util.NewStack(scheds),
		schedulers:              scheds,
		podQueue:                podQueue,
		schedulerSet:            schedulerSet,
		numConcurrentSchedulers: numConcurrentSchedulers,
		waitForSubSchedulers:    waitForSubSchedulers,
		relayOnly:               relayOnly,
		flightRecorder:          flightRecorder,
		webhookServer:           nil,
	}, nil
}

func runNodeCountMetric(ctx context.Context, scheduler *scheduler.Scheduler) {
	ticker := time.NewTicker(10 * time.Second)
	last := 0
	nodeCountGauge.Set(float64(last))
	for {
		select {
		case <-ticker.C:
			now := scheduler.Cache.NodeCount()
			if last != now {
				nodeCountGauge.Set(float64(now))
				last = now
			}
		case <-ctx.Done():
			return
		}
	}
}

func getRecorderFactory(cc *schedulerserverconfig.CompletedConfig) profile.RecorderFactory {
	return func(name string) events.EventRecorder {
		return cc.EventBroadcaster.NewRecorder(name)
	}
}

func podScheduleFailure(ctx context.Context, podInfo *framework.QueuedPodInfo, status *framework.Status, schedulerSet *schedulerset.SchedulerSet) {
	logger := klog.FromContext(ctx)
	v4 := logger.V(4)
	v4.Info("podScheduleFailure", "namespace", podInfo.Pod.Namespace, "pod", podInfo.Pod.Name, "status_plugin", status.Plugin())

	schedulerDoneChan := ctx.Value(util.SchedulerDoneChannelKey).(chan struct{})
	schedulerDoneChan <- struct{}{}

	if status.Plugin() == "DefaultBinder" {
		return
	}
	err := status.AsError()
	if err != nil {
		// The UnschedulablePlugins gets wrapped inside FitError instead of on status directly
		if fitErr, ok := err.(*framework.FitError); ok {
			if fitErr.Diagnosis.UnschedulablePlugins.Has("DistPermit") {
				v4.Info("Was denied due to DistPermit, so skipping", "namespace", podInfo.Pod.Namespace, "pod", podInfo.Pod.Name)
				return
			}
			logger.Info("UnschedulablePlugins", "plugins", fitErr.Diagnosis.UnschedulablePlugins)
		} else {
			logger.Error(err, "Unknown error")
		}
	}

	// If we failed prior to DistPermit, then we should send a score of 0
	target := schedulerSet.GetTargetForScoring(fmt.Sprintf("%s/%s", podInfo.Pod.Namespace, podInfo.Pod.Name))
	v4.Info("Failed prior to DistPermit, so sending score of 0", "namespace", podInfo.Pod.Namespace, "pod", podInfo.Pod.Name, "destination_pod", target.PodName)
	distpermit.SendScore(ctx, target, podInfo.Pod.Name, podInfo.Pod.Namespace, "", 0)
}

type Scheduler struct {
	scheduler *scheduler.Scheduler
	nextPod   *v1.Pod
}

func (s *Scheduler) NextPod(_ klog.Logger) (*framework.QueuedPodInfo, error) {
	pod := s.nextPod
	if pod == nil {
		panic("nextPod is nil")
	}
	s.nextPod = nil
	qpi := framework.QueuedPodInfo{
		PodInfo: &framework.PodInfo{},
	}
	qpi.Update(pod)
	return &qpi, nil
}

type DistScheduler struct {
	schedulerStack          *util.Stack[*Scheduler]
	schedulers              []*Scheduler
	podQueue                chan *v1.Pod
	schedulerSet            *schedulerset.SchedulerSet
	numConcurrentSchedulers int
	waitForSubSchedulers    float64
	relayOnly               bool
	flightRecorder          *traceexp.FlightRecorder
	webhookServer           *webhook.WebhookServer
}

func (ds *DistScheduler) Run(ctx context.Context) {
	protoCodec := encoding.GetCodec("proto")
	marshalPod := func(pod *v1.Pod) func() ([]byte, error) {
		return func() ([]byte, error) {
			// Wrap in a NewPodRequest to that Relay can add the requestId field
			pbPod := &podservice.NewPodRequest{
				Pod: pod,
			}
			return protoCodec.Marshal(pbPod)
		}
	}

	ds.schedulerStack = util.NewStack(ds.schedulers)

	if !ds.relayOnly {
		ds.flightRecorder.Start()
		defer ds.flightRecorder.Stop()
	}

	for i := 0; i < ds.numConcurrentSchedulers; i++ {
		go func() {
			for {
				select {
				case <-ctx.Done():
					logger := klog.FromContext(ctx).WithName("DistScheduler").WithValues("scheduler", i)
					logger.Info("Context done")
					return
				case pod := <-ds.podQueue:
					err := ds.ProcessOne(ctx, i, pod, marshalPod(pod))
					if err != nil {
						logger := klog.FromContext(ctx).WithName("DistScheduler").WithValues("scheduler", i)
						logger.Error(err, "failed to process pod", "pod", pod.Name)
					}
				}
			}
		}()
	}

	// Wait for context cancellation
	<-ctx.Done()

	// Stop the webhook server
	if ds.webhookServer != nil {
		if err := ds.webhookServer.Stop(); err != nil {
			klog.Error(err, "Error stopping webhook server")
		}
	}
}

func (ds *DistScheduler) ProcessOne(ctx context.Context, schedulerIndex int, pod *v1.Pod, getRawPod func() ([]byte, error)) error {
	// schedulerIndex cannot be the same for two separate concurrent goroutines

	// getRawPod can be nil, in which case we do not relay the pod
	ctx, task := trace.NewTask(ctx, fmt.Sprintf("ProcessOne-%s", pod.Name))
	trace.Log(ctx, "pod", pod.Name)
	defer task.End()

	logger := klog.FromContext(ctx).WithName("DistScheduler").WithValues("pod", pod.Name, "scheduler", schedulerIndex)
	v2 := logger.V(2)

	doLog := pod.Name[len(pod.Name)-1] == '0' && pod.Name[len(pod.Name)-2] == '0'
	if doLog {
		logger.Info("Processing pod", "queue_len", len(ds.podQueue), "available_schedulers", ds.schedulerStack.Len())
	} else {
		v2.Info("Processing pod", "queue_len", len(ds.podQueue), "available_schedulers", ds.schedulerStack.Len())
	}

	var wgForRelay util.CountDownLatch
	if getRawPod != nil {
		// Relay the pod to sub-schedulers
		rgn := trace.StartRegion(ctx, "RelayPod")
		timeStart := time.Now()
		var err error
		wgForRelay, err = RelayPod(ctx, getRawPod, ds.schedulerSet, ds.waitForSubSchedulers, schedulerIndex)
		if err != nil {
			return err
		}
		duration := time.Since(timeStart).Seconds()
		scheduleOneRelayCounter.Inc()
		scheduleOneRelayTime.Add(duration)
		logger.V(4).Info("RelayPod took", "time_ms", duration*1000)
		rgn.End()
	}

	if !ds.relayOnly {
		scheduler := ds.schedulerStack.Pop()

		// Now schedule the pod ourselves
		// This other queue is pulled by the scheduler
		if scheduler.nextPod != nil {
			panic("nextPod is not nil")
		}
		scheduler.nextPod = pod

		// This will block past Permit(), up until the binding is made
		// But we really want to be able to continue once the CollectScore() call is in invoked
		schedulerDoneChan := make(chan struct{}, 4)
		ctx = context.WithValue(ctx, util.SchedulerDoneChannelKey, schedulerDoneChan)
		timeStart := time.Now()
		go func() {
			// schedulerDone can end at a few different places:
			// 1. DistPermit.Permit(), prior to sending the score
			// 2. podScheduleFailure
			// 3. The completion of ScheduleOne(), as pushed below
			// Any one of these is sufficient for us to proceed

			if doLog {
				logger.Info("About to ScheduleOne()", "pod", pod.Name)
			}
			rgn := trace.StartRegion(ctx, "ScheduleOne")
			scheduler.scheduler.ScheduleOne(ctx)
			schedulerDoneChan <- struct{}{}
			rgn.End()
		}()
		<-schedulerDoneChan
		duration := time.Since(timeStart)
		scheduleOneTime.Add(duration.Seconds())
		scheduleOneCounter.Inc()

		// Binding and post-binding may still be running in the background, but it is now safe to re-use the scheduler
		ds.schedulerStack.Push(scheduler)
		if doLog {
			logger.Info("ScheduleOne took", "time_us", duration.Microseconds())
			if duration.Milliseconds() > 10 {
				fn := fmt.Sprintf("/tmp/flight-%s-%d.perf", pod.Name, time.Now().UnixMilli())
				fd, err := os.Create(fn)
				if err != nil {
					logger.Error(err, "Failed to create flight file", "file", fn)
				} else {
					ds.flightRecorder.WriteTo(fd)
					fd.Close()
				}
			}
		} else {
			// v2.Info("ScheduleOne took", "time_us", duration.Microseconds())
		}
	}

	if wgForRelay != nil {
		rgn := trace.StartRegion(ctx, "WaitForSubscheduler")
		timeStart := time.Now()
		tctx, cancel := context.WithTimeout(ctx, 1*time.Second)
		defer cancel()

		done := make(chan struct{})
		go func() {
			wgForRelay.Wait()
			close(done)
		}()

		select {
		case <-done:
			// Wait completed normally
		case <-tctx.Done():
			// Timeout occurred
			logger.Info("Timeout waiting for relay operations to complete")
		}
		duration := time.Since(timeStart)
		waitForSubschedulerTime.Add(duration.Seconds())
		if doLog {
			logger.Info("WaitForSubscheduler took", "time_us", duration.Microseconds())
		} else {
			v2.Info("WaitForSubscheduler took", "time_us", duration.Microseconds())
		}
		rgn.End()
	}
	return nil
}
