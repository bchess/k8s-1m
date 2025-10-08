// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package distpermit

import (
	"context"
	"fmt"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"bchess.org/dist-scheduler/pkg/schedulerset"
	"bchess.org/dist-scheduler/pkg/util"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/klog/v2"
	"k8s.io/kubernetes/pkg/scheduler/framework"

	"bchess.org/dist-scheduler/pkg/podservice"
)

func New(ctx context.Context, obj runtime.Object, handle framework.Handle, schedulerSet *schedulerset.SchedulerSet, alwaysDeny bool) (framework.Plugin, error) {
	return &distPermit{
		handle:       handle,
		schedulerSet: schedulerSet,
		alwaysDeny:   alwaysDeny,
	}, nil
}

type distPermit struct {
	handle       framework.Handle
	schedulerSet *schedulerset.SchedulerSet
	alwaysDeny   bool
}

var _ framework.PermitPlugin = &distPermit{}

func (p *distPermit) Name() string {
	return "DistPermit"
}

func (p *distPermit) Permit(ctx context.Context, state *framework.CycleState, pod *v1.Pod, nodeName string) (*framework.Status, time.Duration) {
	if p.alwaysDeny {
		return framework.NewStatus(framework.Unschedulable, "Always deny"), 0
	}
	logger := klog.FromContext(ctx).WithName("DistScheduler").WithValues("pod", pod.Name, "namespace", pod.Namespace, "node", nodeName)
	v4 := logger.V(4)
	v4.Info("Permit")
	nodePluginScores, err := state.Read(framework.NodePluginScoresStateKey)
	if err != nil {
		logger.Error(err, "Failed to read node plugin scores")
		return framework.NewStatus(framework.Error, "Failed to read node plugin scores"), 0
	}
	nodePluginScoresState := nodePluginScores.(*framework.NodePluginScoresState)

	target := p.schedulerSet.GetTargetForScoring(fmt.Sprintf("%s/%s", pod.Namespace, pod.Name))

	schedulerDoneChan := ctx.Value(util.SchedulerDoneChannelKey).(chan struct{})
	schedulerDoneChan <- struct{}{}

	for _, nodePluginScore := range nodePluginScoresState.NodePluginScores {
		if nodePluginScore.Name == nodeName {
			permit := SendScore(ctx, target, pod.Name, pod.Namespace, nodeName, nodePluginScore.TotalScore)
			if permit {
				v4.Info("Permit approved")
				return framework.NewStatus(framework.Success, "DistPermit"), 0
			}
			break
		}
	}

	v4.Info("Permit rejected")
	return framework.NewStatus(framework.Unschedulable, "Rejected by CollectScore").WithPlugin("DistPermit"), 0 // reject
}

var clientCacheLock sync.Mutex
var clientCache = make(map[string]*grpc.ClientConn)

func SendScore(ctx context.Context, target schedulerset.EndpointItem, podName string, namespace string, nodeName string, score int64) bool {
	logger := klog.FromContext(ctx).WithName("DistScheduler").WithValues("destination_pod", target.PodName, "destination_addresses", target.Addresses, "pod", podName, "namespace", namespace, "node", nodeName, "score", score)
	addr := util.GRPCAddress(target.Addresses[0], "50051") // TODO: do not hard-code port

	clientCacheLock.Lock()
	conn, ok := clientCache[addr]
	if !ok {
		var err error
		conn, err = grpc.NewClient(
			addr,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			logger.Error(err, "SendScore: did not connect. Denying permit")
			return false
		}
		clientCache[addr] = conn
	}
	clientCacheLock.Unlock()

	client := podservice.NewPodServiceClient(conn)
	request := &podservice.SchedulingScore{
		PodName:   podName,
		Namespace: namespace,
		NodeName:  nodeName,
		Score:     int32(score),
	}
	logger.V(4).Info("Sending to CollectScore")
	if score == 0 {
		// If score is 0 we don't need the response, we know it's a rejection
		go client.CollectScore(ctx, request)
		return false
	}
	response, err := client.CollectScore(ctx, request)
	if err != nil {
		logger.Error(err, "could not send score. Denying permit")
		return false
	}
	logger.V(4).Info("CollectScore response", "permit", response.Permit)
	return response.Permit
}
