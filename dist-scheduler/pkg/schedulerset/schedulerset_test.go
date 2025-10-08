// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package schedulerset

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"k8s.io/client-go/kubernetes/fake"
)

func mockEndpointCache(podNames []string) *EndpointSliceCache {
	endpoints := make([]discoveryv1.Endpoint, len(podNames))
	for i, podName := range podNames {
		endpoints[i] = discoveryv1.Endpoint{
			Addresses: []string{podName},
			TargetRef: &corev1.ObjectReference{
				Kind: "Pod",
				Name: podName,
			},
		}
	}
	endpointSlice := &discoveryv1.EndpointSlice{
		ObjectMeta: metav1.ObjectMeta{Name: "test-pod"},
		Endpoints:  endpoints,
	}
	return &EndpointSliceCache{
		slices: map[string]*discoveryv1.EndpointSlice{
			"test-pod": endpointSlice,
		},
	}
}

func TestGetMemberCount(t *testing.T) {
	tests := []struct {
		name      string
		members   []string
		allowSolo bool
		want      uint32
	}{
		{
			name:      "empty set with allowSolo",
			members:   []string{},
			allowSolo: true,
			want:      1,
		},
		{
			name:      "empty set without allowSolo",
			members:   []string{},
			allowSolo: false,
			want:      0,
		},
		{
			name:      "multiple members",
			members:   []string{"scheduler-1", "scheduler-2", "scheduler-3"},
			allowSolo: false,
			want:      3,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cs := fake.NewSimpleClientset()
			ss, err := NewSchedulerSet(context.Background(), cs, "default", "test-pod", 10, tt.allowSolo)
			if err != nil {
				t.Fatalf("NewSchedulerSet() error = %v", err)
			}

			// Inject test members directly into the cache
			ss.endpointSliceCache = mockEndpointCache(tt.members)

			got := ss.GetMemberCount()
			if got != tt.want {
				t.Errorf("GetMemberCount() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetMemberCountNoRelays(t *testing.T) {
	tests := []struct {
		name    string
		members []string
		want    uint32
	}{
		{
			name:    "empty set",
			members: []string{},
			want:    0,
		},
		{
			name:    "mixed members",
			members: []string{"dist-scheduler-1", "dist-scheduler-relay-1", "dist-scheduler-2", "dist-scheduler-relay-2"},
			want:    2,
		},
		{
			name:    "only schedulers",
			members: []string{"dist-scheduler-1", "dist-scheduler-2"},
			want:    2,
		},
		{
			name:    "only relays",
			members: []string{"dist-scheduler-relay-1", "dist-scheduler-relay-2"},
			want:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cs := fake.NewSimpleClientset()
			ss, err := NewSchedulerSet(context.Background(), cs, "default", "test-pod", 10, false)
			if err != nil {
				t.Fatalf("NewSchedulerSet() error = %v", err)
			}

			ss.endpointSliceCache = mockEndpointCache(tt.members)

			got := ss.GetMemberCountNoRelays()
			if got != tt.want {
				t.Errorf("GetMemberCountNoRelays() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetSubMembers(t *testing.T) {
	bigPodNameList := []string{
		"dist-scheduler-855b885c5d-24nmt",
		"dist-scheduler-855b885c5d-28r24",
		"dist-scheduler-855b885c5d-49ntc",
		"dist-scheduler-855b885c5d-4cfqz",
		"dist-scheduler-855b885c5d-5lt9t",
		"dist-scheduler-855b885c5d-5nt7m",
		"dist-scheduler-855b885c5d-64dfc",
		"dist-scheduler-855b885c5d-6ld8m",
		"dist-scheduler-855b885c5d-6nh2k",
		"dist-scheduler-855b885c5d-6p5cd",
		"dist-scheduler-855b885c5d-6sl2r",
		"dist-scheduler-855b885c5d-72lpj",
		"dist-scheduler-855b885c5d-7lppz",
		"dist-scheduler-855b885c5d-8jz5m",
		"dist-scheduler-855b885c5d-8s96b",
		"dist-scheduler-855b885c5d-8wkmk",
		"dist-scheduler-855b885c5d-9r6lp",
		"dist-scheduler-855b885c5d-9vfnb",
		"dist-scheduler-855b885c5d-bq8t6",
		"dist-scheduler-855b885c5d-bs7sc",
		"dist-scheduler-855b885c5d-c2m2z",
		"dist-scheduler-855b885c5d-clrpq",
		"dist-scheduler-855b885c5d-cvdbv",
		"dist-scheduler-855b885c5d-dp7vs",
		"dist-scheduler-855b885c5d-dvjlk",
		"dist-scheduler-855b885c5d-fdzll",
		"dist-scheduler-855b885c5d-fzt8f",
		"dist-scheduler-855b885c5d-gbsdl",
		"dist-scheduler-855b885c5d-gmkw4",
		"dist-scheduler-855b885c5d-gwbs2",
		"dist-scheduler-855b885c5d-hmqsg",
		"dist-scheduler-855b885c5d-j7nd4",
		"dist-scheduler-855b885c5d-jw44t",
		"dist-scheduler-855b885c5d-k742f",
		"dist-scheduler-855b885c5d-kh47k",
		"dist-scheduler-855b885c5d-lw8kf",
		"dist-scheduler-855b885c5d-lzd7g",
		"dist-scheduler-855b885c5d-m5ng4",
		"dist-scheduler-855b885c5d-mfc7z",
		"dist-scheduler-855b885c5d-mp5j6",
		"dist-scheduler-855b885c5d-n5nm2",
		"dist-scheduler-855b885c5d-nc4hk",
		"dist-scheduler-855b885c5d-njvwr",
		"dist-scheduler-855b885c5d-p4tv5",
		"dist-scheduler-855b885c5d-pkdjl",
		"dist-scheduler-855b885c5d-q6j7d",
		"dist-scheduler-855b885c5d-qq4nt",
		"dist-scheduler-855b885c5d-rjpnz",
		"dist-scheduler-855b885c5d-rl7cg",
		"dist-scheduler-855b885c5d-rpcvl",
		"dist-scheduler-855b885c5d-snfzb",
		"dist-scheduler-855b885c5d-sphxf",
		"dist-scheduler-855b885c5d-tc89d",
		"dist-scheduler-855b885c5d-tspqr",
		"dist-scheduler-855b885c5d-vqpk9",
		"dist-scheduler-855b885c5d-w69gp",
		"dist-scheduler-855b885c5d-wmbft",
		"dist-scheduler-855b885c5d-xfqcf",
		"dist-scheduler-855b885c5d-xhgx8",
		"dist-scheduler-855b885c5d-z5fw2",
		"dist-scheduler-855b885c5d-zjdkk",
		"dist-scheduler-855b885c5d-znx8s",
		"dist-scheduler-855b885c5d-zpp8z",
		"dist-scheduler-855b885c5d-zzd5n",
		"dist-scheduler-relay-7b8847c594-4pzl9",
		"dist-scheduler-relay-7b8847c594-5965t",
		"dist-scheduler-relay-7b8847c594-596z8",
		"dist-scheduler-relay-7b8847c594-8tqd2",
		"dist-scheduler-relay-7b8847c594-9ssqq",
		"dist-scheduler-relay-7b8847c594-jhr44",
		"dist-scheduler-relay-7b8847c594-rch8w",
	}
	tests := []struct {
		name    string
		leader  string
		podName string
		members []string
		want    []string
	}{
		{
			name:    "empty set",
			leader:  "",
			podName: "",
			members: []string{},
			want:    []string{},
		},
		{
			name:    "leader",
			leader:  "dist-scheduler-relay-7b8847c594-8tqd2",
			members: bigPodNameList,
			podName: "dist-scheduler-relay-7b8847c594-8tqd2",
			want: []string{
				"dist-scheduler-relay-7b8847c594-4pzl9",
				"dist-scheduler-relay-7b8847c594-5965t",
				"dist-scheduler-relay-7b8847c594-596z8",
				"dist-scheduler-relay-7b8847c594-9ssqq",
				"dist-scheduler-relay-7b8847c594-jhr44",
				"dist-scheduler-relay-7b8847c594-rch8w",
				"dist-scheduler-855b885c5d-24nmt",
				"dist-scheduler-855b885c5d-28r24",
				"dist-scheduler-855b885c5d-49ntc",
				"dist-scheduler-855b885c5d-4cfqz",
			},
		},
		{
			name:    "relay1",
			leader:  "dist-scheduler-relay-7b8847c594-8tqd2",
			members: bigPodNameList,
			podName: "dist-scheduler-relay-7b8847c594-4pzl9",
			want: []string{
				"dist-scheduler-855b885c5d-5lt9t",
				"dist-scheduler-855b885c5d-5nt7m",
				"dist-scheduler-855b885c5d-64dfc",
				"dist-scheduler-855b885c5d-6ld8m",
				"dist-scheduler-855b885c5d-6nh2k",
				"dist-scheduler-855b885c5d-6p5cd",
				"dist-scheduler-855b885c5d-6sl2r",
				"dist-scheduler-855b885c5d-72lpj",
				"dist-scheduler-855b885c5d-7lppz",
				"dist-scheduler-855b885c5d-8jz5m",
			},
		},
		{
			name:    "relay2",
			leader:  "dist-scheduler-relay-7b8847c594-8tqd2",
			members: bigPodNameList,
			podName: "dist-scheduler-relay-7b8847c594-5965t",
			want: []string{
				"dist-scheduler-855b885c5d-8s96b",
				"dist-scheduler-855b885c5d-8wkmk",
				"dist-scheduler-855b885c5d-9r6lp",
				"dist-scheduler-855b885c5d-9vfnb",
				"dist-scheduler-855b885c5d-bq8t6",
				"dist-scheduler-855b885c5d-bs7sc",
				"dist-scheduler-855b885c5d-c2m2z",
				"dist-scheduler-855b885c5d-clrpq",
				"dist-scheduler-855b885c5d-cvdbv",
				"dist-scheduler-855b885c5d-dp7vs",
			},
		},
		{
			name:    "dist-scheduler",
			leader:  "dist-scheduler-relay-7b8847c594-8tqd2",
			members: bigPodNameList,
			podName: "dist-scheduler-855b885c5d-24nmt",
			want:    []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cs := fake.NewSimpleClientset()
			ss, err := NewSchedulerSet(context.Background(), cs, "default", tt.podName, 10, false)
			if err != nil {
				t.Fatalf("NewSchedulerSet() error = %v", err)
			}

			ss.endpointSliceCache = mockEndpointCache(tt.members)
			ss.SetLeader(tt.leader)
			got := ss.GetSubMembers()
			if len(got) != len(tt.want) {
				t.Errorf("GetSubMembers() = %v, want %v", got, tt.want)
			}
			for i, member := range got {
				if member.PodName != tt.want[i] {
					t.Errorf("GetSubMembers() = %v, want %v", got, tt.want)
				}
			}
		})
	}
}
