// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"net/http"
	goruntime "runtime"
	"sync"

	"k8s.io/apiserver/pkg/authentication/authenticator"
	"k8s.io/apiserver/pkg/authorization/authorizer"
	genericapifilters "k8s.io/apiserver/pkg/endpoints/filters"
	apirequest "k8s.io/apiserver/pkg/endpoints/request"
	genericfilters "k8s.io/apiserver/pkg/server/filters"
	"k8s.io/apiserver/pkg/server/healthz"
	"k8s.io/apiserver/pkg/server/mux"
	"k8s.io/apiserver/pkg/server/routes"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/component-base/configz"
	"k8s.io/component-base/logs"
	"k8s.io/component-base/metrics"
	"k8s.io/component-base/metrics/legacyregistry"
	"k8s.io/component-base/metrics/prometheus/slis"
	kubeschedulerconfig "k8s.io/kubernetes/pkg/scheduler/apis/config"
	"k8s.io/kubernetes/pkg/scheduler/metrics/resources"
)

// buildHandlerChain wraps the given handler with the standard filters.
func buildHandlerChain(handler http.Handler, authn authenticator.Request, authz authorizer.Authorizer) http.Handler {
	requestInfoResolver := &apirequest.RequestInfoFactory{}
	failedHandler := genericapifilters.Unauthorized(scheme.Codecs)

	handler = genericapifilters.WithAuthorization(handler, authz, scheme.Codecs)
	handler = genericapifilters.WithAuthentication(handler, authn, failedHandler, nil, nil)
	handler = genericapifilters.WithRequestInfo(handler, requestInfoResolver)
	handler = genericapifilters.WithCacheControl(handler)
	handler = genericfilters.WithHTTPLogging(handler)
	handler = genericfilters.WithPanicRecovery(handler, requestInfoResolver)

	return handler
}

func installMetricHandler(pathRecorderMux *mux.PathRecorderMux, informers informers.SharedInformerFactory, isLeader func() bool) {
	configz.InstallHandler(pathRecorderMux)
	pathRecorderMux.Handle("/metrics", legacyregistry.HandlerWithReset())

	resourceMetricsHandler := resources.Handler(informers.Core().V1().Pods().Lister())
	pathRecorderMux.HandleFunc("/metrics/resources", func(w http.ResponseWriter, req *http.Request) {
		if !isLeader() {
			return
		}
		resourceMetricsHandler.ServeHTTP(w, req)
	})
}

// newHealthEndpointsAndMetricsHandler creates an API health server from the config, and will also
// embed the metrics handler.
// TODO: healthz check is deprecated, please use livez and readyz instead. Will be removed in the future.
func newHealthEndpointsAndMetricsHandler(config *kubeschedulerconfig.KubeSchedulerConfiguration, informers informers.SharedInformerFactory, isLeader func() bool, healthzChecks, readyzChecks []healthz.HealthChecker) http.Handler {
	pathRecorderMux := mux.NewPathRecorderMux("kube-scheduler")
	healthz.InstallHandler(pathRecorderMux, healthzChecks...)
	healthz.InstallLivezHandler(pathRecorderMux)
	healthz.InstallReadyzHandler(pathRecorderMux, readyzChecks...)
	installMetricHandler(pathRecorderMux, informers, isLeader)
	slis.SLIMetricsWithReset{}.Install(pathRecorderMux)

	if config.EnableProfiling {
		routes.Profiling{}.Install(pathRecorderMux)
		if config.EnableContentionProfiling {
			goruntime.SetBlockProfileRate(1)
		}
		routes.DebugFlags{}.Install(pathRecorderMux, "v", routes.StringFlagPutHandler(logs.GlogSetter))
	}
	return pathRecorderMux
}

var (
	parallelismGauge = metrics.NewGauge(
		&metrics.GaugeOpts{
			Name: "distscheduler_parallelism",
			Help: "Parallelism for filtering and scoring",
		},
	)
	numSchedulersGauge = metrics.NewGauge(
		&metrics.GaugeOpts{
			Name: "distscheduler_num_schedulers",
			Help: "Number of schedulers",
		},
	)
	podObservedCounter = metrics.NewCounter(
		&metrics.CounterOpts{
			Name:           "distscheduler_pod_observed_count",
			Help:           "Number of pods observed by the dist-scheduler watcher.",
			StabilityLevel: metrics.STABLE,
		},
	)
	podRelayCounter = metrics.NewCounterVec(
		&metrics.CounterOpts{
			Name:           "distscheduler_pod_relay_count",
			Help:           "Number of individual relays made to sub-schedulers (can be multiple per pod)",
			StabilityLevel: metrics.STABLE,
		},
		[]string{"destination_pod"},
	)
	podRelayTime = metrics.NewCounterVec(
		&metrics.CounterOpts{
			Name:           "distscheduler_pod_relay_time_seconds",
			Help:           "Total time taken to relay pods to sub-schedulers",
			StabilityLevel: metrics.STABLE,
		},
		[]string{"destination_pod"},
	)
	scheduleOneRelayCounter = metrics.NewCounter(
		&metrics.CounterOpts{
			Name:           "distscheduler_schedule_one_relay_count",
			Help:           "Number of times ScheduleOne() did relays",
			StabilityLevel: metrics.STABLE,
		},
	)
	scheduleOneRelayTime = metrics.NewCounter(
		&metrics.CounterOpts{
			Name:           "distscheduler_schedule_one_relay_time_seconds",
			Help:           "Total time taken to relay pods to sub-schedulers",
			StabilityLevel: metrics.STABLE,
		},
	)
	scheduleOneCounter = metrics.NewCounter(
		&metrics.CounterOpts{
			Name:           "distscheduler_schedule_one_count",
			Help:           "Number of times ScheduleOne() was called",
			StabilityLevel: metrics.STABLE,
		},
	)
	scheduleOneTime = metrics.NewCounter(
		&metrics.CounterOpts{
			Name:           "distscheduler_schedule_one_time_seconds",
			Help:           "Total time taken in ScheduleOne()",
			StabilityLevel: metrics.STABLE,
		},
	)
	waitForSubschedulerTime = metrics.NewCounter(
		&metrics.CounterOpts{
			Name:           "distscheduler_wait_for_subscheduler_time_seconds",
			Help:           "Total time waiting for sub-schedulers to complete",
			StabilityLevel: metrics.STABLE,
		},
	)
	nodeCountGauge = metrics.NewGauge(
		&metrics.GaugeOpts{
			Name: "distscheduler_node_count",
			Help: "Number of nodes in the cache",
		},
	)
	podRelayRecvMsgTime = metrics.NewCounterVec(
		&metrics.CounterOpts{
			Name:           "distscheduler_pod_relay_recv_msg_time_seconds",
			Help:           "Total time taken to receive messages from sub-schedulers",
			StabilityLevel: metrics.STABLE,
		},
		[]string{"destination_pod"},
	)
	podRelayRecvMsgInnerTime = metrics.NewCounterVec(
		&metrics.CounterOpts{
			Name:           "distscheduler_pod_relay_recv_msg_inner_time_seconds",
			Help:           "Total time taken to receive messages from sub-schedulers",
			StabilityLevel: metrics.STABLE,
		},
		[]string{"destination_pod"},
	)
	once sync.Once
)

func registerMetrics() {
	once.Do(func() {
		legacyregistry.MustRegister(parallelismGauge)
		legacyregistry.MustRegister(numSchedulersGauge)
		legacyregistry.MustRegister(podObservedCounter)
		legacyregistry.MustRegister(podRelayCounter)
		legacyregistry.MustRegister(podRelayTime)
		legacyregistry.MustRegister(scheduleOneRelayCounter)
		legacyregistry.MustRegister(scheduleOneRelayTime)
		legacyregistry.MustRegister(scheduleOneCounter)
		legacyregistry.MustRegister(scheduleOneTime)
		legacyregistry.MustRegister(waitForSubschedulerTime)
		legacyregistry.MustRegister(nodeCountGauge)
		legacyregistry.MustRegister(podRelayRecvMsgTime)
		legacyregistry.MustRegister(podRelayRecvMsgInnerTime)
	})
}
