// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package schedulerset

import (
	"context"
	"fmt"
	"sync"

	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	discoveryinformers "k8s.io/client-go/informers/discovery/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/klog/v2"
)

// EndpointSliceCache holds a map of EndpointSlice objects keyed by their name.
type EndpointSliceCache struct {
	sync.RWMutex
	slices map[string]*discoveryv1.EndpointSlice
}

type EndpointItem struct {
	PodName   string
	Addresses []string
}

func (e EndpointItem) String() string {
	return e.PodName
}

// NewEndpointSliceCache creates a new EndpointSliceCache.
func NewEndpointSliceCache() *EndpointSliceCache {
	return &EndpointSliceCache{
		slices: make(map[string]*discoveryv1.EndpointSlice),
	}
}

// Update inserts or updates an EndpointSlice in the cache.
func (esc *EndpointSliceCache) Update(ess *discoveryv1.EndpointSlice) {
	esc.Lock()
	key := ess.Name // Assumes EndpointSlice names are unique within the namespace.
	esc.slices[key] = ess.DeepCopy()
	esc.Unlock()
}

// Delete removes an EndpointSlice from the cache.
func (esc *EndpointSliceCache) Delete(ess *discoveryv1.EndpointSlice) {
	esc.Lock()
	key := ess.Name
	delete(esc.slices, key)
	esc.Unlock()
}

func (esc *EndpointSliceCache) GetMemberCount() int {
	esc.RLock()
	defer esc.RUnlock()
	count := 0
	for _, slice := range esc.slices {
		count += len(slice.Endpoints)
	}
	return count
}

// GetMembers returns a slice of all IP addresses across the cached EndpointSlices.
func (esc *EndpointSliceCache) GetMembers() []EndpointItem {
	esc.RLock()
	defer esc.RUnlock()

	var members []EndpointItem
	for _, slice := range esc.slices {
		for _, endpoint := range slice.Endpoints {
			// Each endpoint may have multiple IP addresses.
			members = append(members, EndpointItem{
				PodName:   endpoint.TargetRef.Name,
				Addresses: endpoint.Addresses,
			})
		}
	}
	return members
}

// RunEndpointSliceWatcher sets up an informer that watches for EndpointSlice objects
// associated with the "dist-scheduler" Service in the given namespace.
// It updates the global endpointSliceCache with adds, updates and deletes.
func RunEndpointSliceWatcher(
	ctx context.Context,
	cs kubernetes.Interface,
	namespace string,
	serviceName string,
) (*EndpointSliceCache, cache.SharedIndexInformer) {
	tweakListOptions := func(options *metav1.ListOptions) {
		options.LabelSelector = fmt.Sprintf("kubernetes.io/service-name=%s", serviceName)
	}

	endpointSliceCache := NewEndpointSliceCache()
	informer := discoveryinformers.NewFilteredEndpointSliceInformer(cs, namespace, 0, cache.Indexers{}, tweakListOptions)

	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			if ess, ok := obj.(*discoveryv1.EndpointSlice); ok {
				klog.Infof("EndpointSlice added: %s/%s", ess.Namespace, ess.Name)
				endpointSliceCache.Update(ess)
			}
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			var generation int64
			if oldEss, ok := oldObj.(*discoveryv1.EndpointSlice); ok {
				generation = oldEss.Generation
			}
			if newEss, ok := newObj.(*discoveryv1.EndpointSlice); ok {
				// Why do we get updates on the same generation?
				if generation != newEss.Generation {
					klog.Infof("EndpointSlice updated: %s/%s", newEss.Namespace, newEss.Name)
					endpointSliceCache.Update(newEss)
				}
			}
		},
		DeleteFunc: func(obj interface{}) {
			if ess, ok := obj.(*discoveryv1.EndpointSlice); ok {
				klog.Infof("EndpointSlice deleted: %s/%s", ess.Namespace, ess.Name)
				endpointSliceCache.Delete(ess)
			}
		},
	})

	// Start the informer and wait for its cache to sync.
	go informer.Run(ctx.Done())
	cache.WaitForCacheSync(ctx.Done(), informer.HasSynced)
	return endpointSliceCache, informer
}
