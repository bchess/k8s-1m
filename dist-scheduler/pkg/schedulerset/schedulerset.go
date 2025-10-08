// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package schedulerset

import (
	"context"
	"fmt"
	"hash/fnv"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/klog/v2"
)

type SchedulerSet struct {
	endpointSliceCache *EndpointSliceCache
	informer           cache.SharedIndexInformer
	podName            string
	fanOut             uint32
	subMembersCache    []EndpointItem
	cacheLock          sync.RWMutex
	leader             string
	dirty              atomic.Bool
	allowSolo          bool
}

const (
	RelayPrefix     = "dist-scheduler-relay"
	SchedulerPrefix = "dist-scheduler"
)

func NewSchedulerSet(ctx context.Context, cs kubernetes.Interface, namespace string, podName string, fanOut uint32, allowSolo bool) (*SchedulerSet, error) {
	endpointSliceCache, informer := RunEndpointSliceWatcher(ctx, cs, namespace, SchedulerPrefix)
	if !cache.WaitForCacheSync(ctx.Done(), informer.HasSynced) {
		klog.Infof("Timed out waiting for the EndpointSlice informer cache to sync")
		return nil, fmt.Errorf("timed out waiting for the EndpointSlice informer cache to sync")
	}

	ss := &SchedulerSet{
		endpointSliceCache: endpointSliceCache,
		informer:           informer,
		podName:            podName,
		fanOut:             fanOut,
		subMembersCache:    nil,
		cacheLock:          sync.RWMutex{},
		dirty:              atomic.Bool{},
		allowSolo:          allowSolo,
	}
	ss.dirty.Store(true)

	ss.AddUpdateHandler(func() { ss.dirty.Store(true) })

	return ss, nil
}

func (s *SchedulerSet) AddUpdateHandler(handler func()) {
	// Handlers are called when the informer detects a change
	s.informer.AddEventHandler(cache.ResourceEventHandlerDetailedFuncs{
		AddFunc: func(obj interface{}, isInInitialList bool) {
			if isInInitialList {
				return
			}
			handler()
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			if oldObj.(*discoveryv1.EndpointSlice).Generation != newObj.(*discoveryv1.EndpointSlice).Generation {
				handler()
			}
		},
		DeleteFunc: func(obj interface{}) { handler() },
	})
}

func (s *SchedulerSet) GetMemberCount() uint32 {
	memberCount := uint32(s.endpointSliceCache.GetMemberCount())
	if memberCount == 0 && s.allowSolo {
		return 1
	}
	return memberCount
}

func (s *SchedulerSet) GetMemberCountNoRelays() uint32 {
	members := s.endpointSliceCache.GetMembers()
	count := 0
	for _, member := range members {
		if !strings.HasPrefix(member.PodName, RelayPrefix) {
			count++
		}
	}
	return uint32(count)
}

func (s *SchedulerSet) GetMembers() []EndpointItem {
	members := s.endpointSliceCache.GetMembers()
	if len(members) == 0 && s.allowSolo {
		return []EndpointItem{{PodName: s.podName, Addresses: []string{"127.0.0.1"}}}
	}
	return members
}

func (s *SchedulerSet) podNameSort(a, b string) int {
	if a == s.leader {
		return -1
	}
	if b == s.leader {
		return 1
	}
	// Ensure relay pods are at the start of the list
	if strings.HasPrefix(a, RelayPrefix) {
		a = "a" + a
	}
	if strings.HasPrefix(b, RelayPrefix) {
		b = "a" + b
	}
	return strings.Compare(a, b)
}

func (s *SchedulerSet) sortMembers(members []EndpointItem) {
	slices.SortFunc(members, func(a, b EndpointItem) int {
		return s.podNameSort(a.PodName, b.PodName)
	})
}

func (s *SchedulerSet) GetTargetForScoring(key string) EndpointItem {
	members := s.GetMembers()
	if len(members) == 1 {
		return members[0]
	}

	// TODO: cache the sort, or push it into the endpointSliceCache
	s.sortMembers(members)
	hash := fnv.New32()
	hash.Write([]byte(key))
	hashValue := hash.Sum32() % uint32(len(members))

	return members[hashValue]
}

func (s *SchedulerSet) GetSubMembers() []EndpointItem {
	if !s.dirty.Load() {
		s.cacheLock.RLock()
		defer s.cacheLock.RUnlock()
		return s.subMembersCache
	}
	s.cacheLock.Lock()
	defer s.cacheLock.Unlock()

	s.dirty.Store(false)

	members := s.endpointSliceCache.GetMembers()
	if len(members) <= 1 {
		// No other schedulers
		s.subMembersCache = []EndpointItem{}
	} else {
		// When there are 11 or less members, then 0 is the leader and 1-10 are submembers of 0
		// When there are 12-111 members:
		//    0 goes to 1-10
		//    11 and beyond are keys on a consistent hash ring with the 10 members 1-10
		// when there are 112-1111 members:
		//    0 goes to 1-10
		//    11-111 members are keys on a consistent hash ring with the 10 members 1-10
		//    112 and beyond are keys on a consistent hash ring with the 100 members 11-111
		// numLevels := int(math.Log(float64(len(members)-1))/math.Log(float64(s.fanOut))) + 1

		s.sortMembers(members)
		var index int
		if s.leader == s.podName {
			index = 0
		} else {
			index = sort.Search(len(members)-1, func(i int) bool {
				return s.podNameSort(members[i+1].PodName, s.podName) >= 0
			}) + 1
		}

		start := index*10 + 1
		if start >= len(members) {
			s.subMembersCache = []EndpointItem{}
		} else {
			end := start + int(s.fanOut)
			if end > len(members) {
				end = len(members)
			}
			s.subMembersCache = members[start:end]
		}
		klog.Infof("I am %s and my relay subMembers are: %v\n", s.podName, s.subMembersCache)
	}
	return s.subMembersCache
}

func (s *SchedulerSet) SetLeader(leader string) {
	// The pod watcher is chosen via leader election. And then the pod watcher starts
	// relaying pods to the rest of the schedulers. So right now the top of the tree needs to be the
	// pod watcher. I need to think about ways to make this better
	s.cacheLock.Lock()
	defer s.cacheLock.Unlock()
	s.leader = leader
	s.dirty.Store(true)
}
