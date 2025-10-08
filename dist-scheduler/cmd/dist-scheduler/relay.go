// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"bchess.org/dist-scheduler/pkg/podservice"
	"bchess.org/dist-scheduler/pkg/schedulerset"
	"bchess.org/dist-scheduler/pkg/util"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding"
	"k8s.io/klog/v2"
)

func RelayPod(ctx context.Context, getRawPod func() ([]byte, error), schedulerSet *schedulerset.SchedulerSet, waitForSubSchedulers float64, clientIndex int) (util.CountDownLatch, error) {
	members := schedulerSet.GetSubMembers()
	if len(members) == 0 {
		return nil, nil
	}

	// rawPod is a protobuf-encoded NewPodRequest but with just the pod field set
	rawPod, err := getRawPod()
	if err != nil {
		return nil, err
	}

	wg := util.NewCountDownLatch(len(members), waitForSubSchedulers)

	// Hack to get the pod name, but just for logging
	podNameLen := rawPod[7]
	podName := string(rawPod[8 : 8+podNameLen])

	logger := klog.FromContext(ctx).WithName("Relay").WithValues("pod", podName)
	v4 := logger.V(4)

	clientIndexStr := strconv.Itoa(clientIndex)

	for _, member := range members {
		v4.Info("Relaying pod", "destination_pod", member.PodName)
		start := time.Now()
		err := sendPodToEndpoint(ctx, member, rawPod, wg, podName, clientIndexStr)
		if err != nil {
			logger.Error(err, "failed to send pod to", "destination_pod", member.PodName)
			wg.Done()
			continue
		}
		duration := time.Since(start).Seconds()
		v4.Info("Sent pod", "destination_pod", member.PodName, "duration_ms", duration*1000)
		podRelayTime.WithLabelValues(member.PodName).Add(duration)
		podRelayCounter.WithLabelValues(member.PodName).Inc()
	}
	return wg, nil
}

type PendingRequest struct {
	wg      util.CountDownLatch
	start   time.Time
	doLog   bool
	podName string
}

type NewPodStream struct {
	stream           grpc.BidiStreamingClient[podservice.NewPodRequest, podservice.NewPodResponse]
	pendingRequests  sync.Map
	requestIdCounter uint32
}

var clientCacheLock sync.Mutex
var clientCache = make(map[string]*NewPodStream)

func sendPodToEndpoint(ctx context.Context, member schedulerset.EndpointItem, pod []byte, wg util.CountDownLatch, podName string, clientIndex string) error {
	var err error
	cacheKey := member.PodName + "/" + clientIndex

	logger := klog.FromContext(ctx).WithValues("destination_pod", member.PodName)
	v4 := logger.V(4)

	clientCacheLock.Lock()
	cs, ok := clientCache[cacheKey]
	if !ok {
		addr := util.GRPCAddress(member.Addresses[0], "50051") // TODO: do not hard-code port

		// Create a context with timeout for the entire operation
		client, err := grpc.NewClient(
			addr,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithDefaultCallOptions(
				grpc.ForceCodec(&RawCodec{
					ParentCodec: encoding.GetCodec("proto"),
				}),
			),
		)
		if err != nil {
			err = fmt.Errorf("failed NewClient: %w", err)
			clientCacheLock.Unlock()
			return err
		}
		stream, err := podservice.NewPodServiceClient(client).NewPod(context.Background(), grpc.CallContentSubtype(RawCodecName))
		if err != nil {
			err = fmt.Errorf("failed NewPodServiceClient: %w", err)
			clientCacheLock.Unlock()
			return err
		}
		cs = &NewPodStream{
			stream:           stream,
			pendingRequests:  sync.Map{},
			requestIdCounter: 0,
		}
		go cs.receiverLoop(ctx, member)
		clientCache[cacheKey] = cs
	}
	clientCacheLock.Unlock()

	v4.Info("SendPod Calling NewPod", "pod", podName, "destination_addresses", member.Addresses, "cache_key", cacheKey)

	doLog := podName[len(podName)-1] == '0' && podName[len(podName)-2] == '0'
	if doLog {
		logger.Info("SendPodToEndpoint SendMsg", "pod", podName)
	}
	requestId := atomic.AddUint32(&cs.requestIdCounter, 1)
	pr := &PendingRequest{
		wg:      wg,
		start:   time.Now(),
		doLog:   doLog,
		podName: podName,
	}
	cs.pendingRequests.Store(requestId, pr)

	// protobuf-encode the requestId field at the start of the msg
	var requestIdBytes [5]byte
	requestIdBytes[0] = 0x0d // field 1, wiretype fixed32
	binary.LittleEndian.PutUint32(requestIdBytes[1:], requestId)
	msg := append(requestIdBytes[:], pod...)
	err = cs.stream.SendMsg(msg)
	if err != nil {
		err = fmt.Errorf("failed SendMsg: %w", err)
		clientCacheLock.Lock()
		delete(clientCache, cacheKey)
		clientCacheLock.Unlock()
		return err
	}
	v4.Info("SendPodToEndpoint SendMsg", "time_us", time.Since(pr.start).Microseconds())

	return nil
}

func (cs *NewPodStream) receiverLoop(ctx context.Context, member schedulerset.EndpointItem) {
	logger := klog.FromContext(ctx).WithValues("destination_pod", member.PodName)
	// This is the receiver loop for the NewPod stream. Every response gets mapped into the pendingRequests map,
	// and the corresponding latch/waitgroup is marked as done.
	for {
		msg, err := cs.stream.Recv()
		if err != nil {
			logger.Error(err, "failed stream.Recv")
			return
		}
		wg, ok := cs.pendingRequests.LoadAndDelete(msg.RequestId)
		if !ok {
			klog.Warningf("Received response for unknown request %d", msg.RequestId)
			continue
		}
		pr := wg.(*PendingRequest)
		duration := time.Since(pr.start)
		pr.wg.Done()
		podRelayRecvMsgTime.WithLabelValues(member.PodName).Add(duration.Seconds())
		if pr.doLog {
			logger.Info("SendPodToEndpoint RecvMsg", "time_us", duration.Microseconds(), "pod", pr.podName)
		}
	}
}
