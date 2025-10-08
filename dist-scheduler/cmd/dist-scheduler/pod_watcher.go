// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"context"
	"fmt"
	"time"

	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	coreinformers "k8s.io/client-go/informers/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/klog/v2"
)

func startPodWatcher(ctx context.Context, podQueue chan *v1.Pod, cs kubernetes.Interface) {
	klog.Info("Pod watcher started")

	informerFactory := informers.NewSharedInformerFactory(cs, 0)
	podInformer := informerFactory.InformerFor(&v1.Pod{}, newPodInformer)

	logger := klog.FromContext(ctx)
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			if pod, ok := obj.(*v1.Pod); ok {
				if pod.Name[len(pod.Name)-1] == '0' && pod.Name[len(pod.Name)-2] == '0' {
					logger.Info("New unscheduled pod added", "namespace", pod.Namespace, "pod", pod.Name, "qs", len(podQueue))
				} else {
					logger.V(2).Info("New unscheduled pod added", "namespace", pod.Namespace, "pod", pod.Name, "qs", len(podQueue))
				}
				if pod.Spec.SchedulerName != "dist-scheduler" {
					// TODO: maybe avoid hard-coding
					return
				}
				podObservedCounter.Inc()
				podQueue <- pod
			}
		},
	})
	informerFactory.Start(ctx.Done())

	// Block this function until the context is cancelled.
	go func() {
		<-ctx.Done()
		klog.Infoln("Pod watcher stopped")
	}()
}

func newPodInformer(cs kubernetes.Interface, resyncPeriod time.Duration) cache.SharedIndexInformer {
	selector := fmt.Sprintf("status.phase!=%v,status.phase!=%v,spec.nodeName=", v1.PodSucceeded, v1.PodFailed)
	tweakListOptions := func(options *metav1.ListOptions) {
		options.FieldSelector = selector
	}
	informer := coreinformers.NewFilteredPodInformer(cs, metav1.NamespaceAll, resyncPeriod, cache.Indexers{}, tweakListOptions)

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
}
