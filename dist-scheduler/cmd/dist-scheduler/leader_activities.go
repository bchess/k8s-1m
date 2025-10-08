// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"os"
	goruntime "runtime"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"bchess.org/dist-scheduler/pkg/schedulerset"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
	"k8s.io/klog/v2"
)

func StartLeaderActivities(ctx context.Context,
	podName string,
	namespace string,
	podQueue chan *v1.Pod,
	cs kubernetes.Interface,
	schedulerSet *schedulerset.SchedulerSet,
	watchPods bool,
	nodeSelector string,
) {
	lock, err := resourcelock.New(resourcelock.LeasesResourceLock,
		namespace,        // Namespace where the lock will live.
		"dist-scheduler", // Name of the resource lock.
		cs.CoreV1(),
		cs.CoordinationV1(),
		resourcelock.ResourceLockConfig{
			Identity: podName,
		})
	if err != nil {
		log.Fatalf("Error creating lock: %v", err)
	}
	leaderConfig := leaderelection.LeaderElectionConfig{
		Lock:          lock,
		LeaseDuration: 15 * time.Second,
		RenewDeadline: 10 * time.Second,
		RetryPeriod:   2 * time.Second,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(lctx context.Context) {
				// lctx will cancel when the leader election stops
				klog.Infof("Became leader: %s", podName)
				startNodeLabeler(lctx, schedulerSet, cs, nodeSelector)
				if watchPods {
					startPodWatcher(lctx, podQueue, cs)
				}
				manageWebhookEndpoints(lctx, namespace, cs)
			},
			OnStoppedLeading: func() {
				// lctx will cancel when the leader election stops
				klog.Infof("Lost leadership: %s", podName)
				// Clear webhook endpoints when losing leadership
				if err := clearWebhookEndpoints(context.Background(), namespace, cs); err != nil {
					klog.Error(err, "Error clearing webhook endpoints")
				}
			},
			OnNewLeader: func(leader string) {
				klog.Infof("New leader: %s", leader)
				schedulerSet.SetLeader(leader)
			},
		},
	}

	elector, err := leaderelection.NewLeaderElector(leaderConfig)
	if err != nil {
		log.Fatalf("Error creating leader elector: %v", err)
	}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			default:
				elector.Run(ctx)
			}
		}
	}()
}

func startNodeLabeler(ctx context.Context, schedulerSet *schedulerset.SchedulerSet, cs kubernetes.Interface, labelSelector string) {
	klog.Infoln("Node labeler started")

	// Not sure why this is needed
	metaGV := schema.GroupVersion{Group: "meta.k8s.io", Version: "v1"}
	scheme.Scheme.AddKnownTypes(metaGV,
		&metav1.PartialObjectMetadata{},
		&metav1.PartialObjectMetadataList{},
	)

	restClient := cs.CoreV1().RESTClient()

	lw := &cache.ListWatch{
		ListFunc: func(options metav1.ListOptions) (runtime.Object, error) {
			if labelSelector != "" {
				options.LabelSelector = labelSelector
			}
			result := &metav1.PartialObjectMetadataList{}
			err := restClient.Get().
				Resource("nodes").
				VersionedParams(&options, scheme.ParameterCodec).
				SetHeader("Accept", "application/vnd.kubernetes.protobuf;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1,application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1,application/json").
				Do(context.Background()).
				Into(result)
			return result, err
		},
		WatchFunc: func(options metav1.ListOptions) (watch.Interface, error) {
			if labelSelector != "" {
				options.LabelSelector = labelSelector
			}
			return restClient.Get().
				Resource("nodes").
				VersionedParams(&options, scheme.ParameterCodec).
				SetHeader("Accept", "application/vnd.kubernetes.protobuf;as=PartialObjectMetadata;g=meta.k8s.io;v=v1,application/json;as=PartialObjectMetadata;g=meta.k8s.io;v=v1,application/json").
				Param("watch", "true").
				Watch(context.Background())
		},
	}

	minInterval := 30 * time.Second

	dirty := atomic.Bool{}
	dirty.Store(true)
	lastUpdateTime := time.Now()
	dirtyChan := make(chan struct{})

	stateChanged := func() {
		// klog.Debugln("State changed")
		dirty.Store(true)
		if time.Since(lastUpdateTime) > minInterval {
			dirtyChan <- struct{}{}
		}
	}
	schedulerSet.AddUpdateHandler(stateChanged)

	emptyMap := map[string]string{}
	nodeInformer := cache.NewSharedInformer(lw, &metav1.PartialObjectMetadata{}, 0)
	nodeInformer.SetTransform(func(obj interface{}) (interface{}, error) {
		// Save memory by stripping everything we don't need
		n := obj.(*metav1.PartialObjectMetadata)
		n.ManagedFields = nil
		n.Annotations = nil
		n.OwnerReferences = nil
		n.Finalizers = nil
		v, exists := n.Labels[SchedulerGroupLabelKey]
		labels := emptyMap
		if exists {
			labels = map[string]string{}
			labels[SchedulerGroupLabelKey] = v
		}
		n.Labels = labels
		return n, nil
	})
	go nodeInformer.Run(ctx.Done())

	nodeInformer.AddEventHandler(cache.ResourceEventHandlerDetailedFuncs{
		AddFunc: func(obj interface{}, isInInitialList bool) {
			// Use meta.Accessor to extract the metadata.
			if isInInitialList {
				return
			}
			metadata, err := meta.Accessor(obj)
			if err != nil {
				klog.Infof("Error accessing metadata on add: %v", err)
				return
			}
			klog.Infof("Node added: %s\n", metadata.GetName())
			stateChanged()
		},
		DeleteFunc: func(obj interface{}) {
			metadata, err := meta.Accessor(obj)
			if err != nil {
				klog.Infof("Error accessing metadata on delete: %v", err)
				return
			}
			klog.Infof("Node deleted: %s\n", metadata.GetName())
			stateChanged()
		},
	})

	cache.WaitForCacheSync(ctx.Done(), nodeInformer.HasSynced)
	klog.Infof("this many nodes: %v\n", len(nodeInformer.GetStore().ListKeys()))
	updateNodeLabels(ctx, schedulerSet, nodeInformer, cs)
	lastUpdateTime = time.Now()

	go func() {
		ticker := time.NewTicker(minInterval)
		for {
			select {
			case <-ctx.Done():
				klog.Infoln("Node labeler stopped")
				return
			case <-dirtyChan:
				if dirty.Swap(false) {
					updateNodeLabels(ctx, schedulerSet, nodeInformer, cs)
					lastUpdateTime = time.Now()
				}
			case <-ticker.C:
				if dirty.Swap(false) {
					updateNodeLabels(ctx, schedulerSet, nodeInformer, cs)
					lastUpdateTime = time.Now()
				}
			}
		}
	}()
}

func updateNodeLabels(ctx context.Context, schedulerSet *schedulerset.SchedulerSet, nodeInformer cache.SharedInformer, cs kubernetes.Interface) {
	// Re-distribute nodes to schedulers evenly, and minimize the number of nodes moved.
	klog.Infoln("Updating node labels")
	schedulers := schedulerSet.GetMembers()
	schedulers = slices.DeleteFunc(schedulers, func(m schedulerset.EndpointItem) bool {
		// exclude relay pods
		return strings.HasPrefix(m.PodName, schedulerset.RelayPrefix)
	})

	nodeCountPerGroup := make(map[string]int, len(schedulers))
	for _, m := range schedulers {
		nodeCountPerGroup[m.PodName] = 0
	}

	nodeList := nodeInformer.GetStore().List()
	toMove := make([]metav1.Object, 0, len(nodeList)/10)

	if len(schedulers) == 0 {
		klog.Info("No schedulers, skipping node label update")
		return
	}

	desiredNodeCountPerGroup := int(math.Ceil(float64(len(nodeList)) / float64(len(schedulers))))
	shortGroups := make([]string, 0)

	for _, n := range nodeList {
		n := n.(metav1.Object)
		currentGroup, ok := n.GetLabels()[SchedulerGroupLabelKey]
		// If the node is not labeled, or the label is to a scheduler that is not in the schedulerSet,
		// or if the assigned scheduler already has too many members, add it to the list of nodes to move.
		var count int
		if ok {
			count, ok = nodeCountPerGroup[currentGroup]
		}
		if ok && count < desiredNodeCountPerGroup {
			nodeCountPerGroup[currentGroup]++
		} else {
			toMove = append(toMove, n)
		}
	}
	if len(toMove) == 0 {
		klog.Info("Moved 0 nodes\n")
		return
	}

	for group, count := range nodeCountPerGroup {
		if count < desiredNodeCountPerGroup {
			shortGroups = append(shortGroups, group)
		}
	}
	if len(shortGroups) == 0 {
		klog.Info("All groups are full")
		return
	}

	movedCount := int32(0)
	nodeLabelParallelism := 1000 // TODO: make this configurable
	sem := make(chan struct{}, nodeLabelParallelism)

	for i, node := range toMove {
		desiredPartition := shortGroups[i%len(shortGroups)]
		nodeCountPerGroup[desiredPartition]++
		if nodeCountPerGroup[desiredPartition] >= desiredNodeCountPerGroup {
			shortGroups = slices.Delete(shortGroups, i%len(shortGroups), i%len(shortGroups)+1)
		}

		// This shouldn't happen but just checking
		labels := node.GetLabels()
		currentPartition := labels[SchedulerGroupLabelKey]
		if currentPartition == desiredPartition {
			klog.Errorf("Node %s is already in the desired partition %s", node.GetName(), desiredPartition)
			continue
		}

		// Build a patch to set the label
		patch := map[string]interface{}{
			"metadata": map[string]interface{}{
				"labels": map[string]string{
					SchedulerGroupLabelKey: desiredPartition,
				},
			},
		}
		patchBytes, err := json.Marshal(patch)
		if err != nil {
			klog.Infof("Error marshaling patch: %v", err)
			continue
		}

		sem <- struct{}{}
		go func(nodeName string) {
			// Use this instead of client.Nodes().Patch() to avoid unmarshalling the response
			_, err := cs.CoreV1().RESTClient().Patch(types.MergePatchType).
				Resource("nodes").
				Name(nodeName).
				Body(patchBytes).
				Do(ctx).
				Raw()
			if err != nil {
				klog.Infof("Error updating node labels: %v", err)
			} else {
				atomic.AddInt32(&movedCount, 1)
			}
			<-sem
		}(node.GetName())

		if i%65536 == 65535 {
			goruntime.GC()
		}
	}

	// Wait for all goroutines to complete
	for i := 0; i < nodeLabelParallelism; i++ {
		sem <- struct{}{}
	}
	klog.Infof("Moved %d nodes\n", movedCount)
	goruntime.GC()
}

func manageWebhookEndpoints(ctx context.Context, namespace string, cs kubernetes.Interface) {
	// Get pod IP from environment variable
	podIP := os.Getenv("POD_IP")
	if podIP == "" {
		klog.Error(nil, "POD_IP environment variable not set")
		return
	}

	// Create or update the endpoints object
	endpoints := &v1.Endpoints{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "dist-scheduler-webhook",
			Namespace: namespace,
		},
		Subsets: []v1.EndpointSubset{
			{
				Addresses: []v1.EndpointAddress{
					{
						IP: podIP,
					},
				},
				Ports: []v1.EndpointPort{
					{
						Name:     "webhook",
						Port:     8443,
						Protocol: v1.ProtocolTCP,
					},
				},
			},
		},
	}

	// Try to create the endpoints object
	_, err := cs.CoreV1().Endpoints(namespace).Create(ctx, endpoints, metav1.CreateOptions{})
	if err != nil {
		if !errors.IsAlreadyExists(err) {
			klog.Error(err, "Error creating endpoints")
			return
		}
		// If it already exists, update it
		_, err = cs.CoreV1().Endpoints(namespace).Update(ctx, endpoints, metav1.UpdateOptions{})
		if err != nil {
			klog.Error(err, "Error updating endpoints")
			return
		}
	}
}

func clearWebhookEndpoints(ctx context.Context, namespace string, cs kubernetes.Interface) error {
	return cs.CoreV1().Endpoints(namespace).Delete(ctx, "dist-scheduler-webhook", metav1.DeleteOptions{})
}
