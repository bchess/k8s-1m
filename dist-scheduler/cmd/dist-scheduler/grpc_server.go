// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"slices"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/encoding"

	"bchess.org/dist-scheduler/pkg/podservice"
	"bchess.org/dist-scheduler/pkg/schedulerset"
	"bchess.org/dist-scheduler/pkg/scoreevaluator"
	"k8s.io/klog/v2"
)

type podServiceServer struct {
	podservice.UnimplementedPodServiceServer
	scoreEvaluator *scoreevaluator.ScoreEvaluator
	distScheduler  *DistScheduler
	protoCodec     encoding.Codec
}

type concurrentCounter struct {
	mu    sync.Mutex
	total int
	free  []int
}

func (c *concurrentCounter) Get() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.free) > 0 {
		idx := c.free[len(c.free)-1]
		c.free = c.free[:len(c.free)-1]
		return idx
	}
	c.total++
	return c.total - 1
}

func (c *concurrentCounter) Free(idx int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Find the position to insert at for descending order
	pos, _ := slices.BinarySearchFunc(c.free, idx, func(a, b int) int {
		if a > b {
			return -1
		} else if a < b {
			return 1
		}
		return 0
	})
	// Insert at the found position
	c.free = slices.Insert(c.free, pos, idx)
}

var cc concurrentCounter

func (s *podServiceServer) NewPod(stream grpc.BidiStreamingServer[podservice.NewPodRequest, podservice.NewPodResponse]) error {
	// All of the logic has already happened in UnmarshalPodRaw
	for {
		req, err := stream.Recv()
		if err != nil {
			return err
		}
		err = stream.Send(&podservice.NewPodResponse{
			RequestId: req.RequestId,
		})
		if err != nil {
			return err
		}
	}
}

func (s *podServiceServer) UnmarshalPodRaw(bytes []byte, v interface{}) error {
	// this is actually an Unmarshal call. 'v' becomes what is passed to NewPod()
	ctx := context.Background()
	start := time.Now()

	err := s.protoCodec.Unmarshal(bytes, v)
	if err != nil {
		return err
	}
	newPodRequest := v.(*podservice.NewPodRequest)

	// TODO: if ds.relayOnly, then we can skip deserializing the pod. ProcessOne() will still want the name though for logging reasons
	pod := newPodRequest.Pod
	var logger klog.Logger
	if pod.Name[len(pod.Name)-1] == '0' && pod.Name[len(pod.Name)-2] == '0' {
		// logger v2
		logger = klog.FromContext(ctx).WithValues("namespace", pod.ObjectMeta.Namespace, "pod", pod.ObjectMeta.Name)
		logger.Info("Received NewPod")
	}

	idx := cc.Get()
	defer cc.Free(idx)
	s.distScheduler.ProcessOne(ctx, idx, pod, func() ([]byte, error) {
		// Skip the first 5 bytes of the pod, which is the protobuf entry for requestId
		return bytes[5:], nil
	})
	duration := time.Since(start)
	if pod.Name[len(pod.Name)-1] == '0' && pod.Name[len(pod.Name)-2] == '0' {
		logger.Info("Total time", "time_us", duration.Microseconds())
	}

	return nil
}

func (s *podServiceServer) CollectScore(ctx context.Context, score *podservice.SchedulingScore) (*podservice.ScheduleResponse, error) {
	logger := klog.FromContext(ctx)
	logger.V(4).Info("CollectScore", "namespace", score.Namespace, "pod", score.PodName, "node", score.NodeName, "score", score.Score)

	highestScore := s.scoreEvaluator.RecordAndWait(fmt.Sprintf("%s/%s", score.Namespace, score.PodName), scoreevaluator.Score{
		NodeName: score.NodeName,
		Score:    int(score.Score),
	})
	return &podservice.ScheduleResponse{
		Permit: highestScore.NodeName == score.NodeName,
	}, nil
}

func StartGrpcServer(ctx context.Context, address string, schedulerSet *schedulerset.SchedulerSet, distScheduler *DistScheduler) {
	lis, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	scoreEvaluator := scoreevaluator.New(5*time.Second, schedulerSet)
	podServiceServer := &podServiceServer{
		scoreEvaluator: scoreEvaluator,
		distScheduler:  distScheduler,
		protoCodec:     encoding.GetCodec("proto"),
	}

	rawCodec := &RawCodec{
		ParentCodec:   encoding.GetCodec("proto"),
		unmarshalFunc: podServiceServer.UnmarshalPodRaw,
	}
	encoding.RegisterCodec(rawCodec)

	s := grpc.NewServer()
	podservice.RegisterPodServiceServer(s, podServiceServer)
	klog.Infof("gRPC server listening on %s", address)

	go func() {
		go func() {
			<-ctx.Done()
			s.Stop()
		}()
		if err := s.Serve(lis); err != nil {
			log.Fatalf("failed to serve: %v", err)
		}
	}()
}

// RawCodec
const RawCodecName = "newPodRaw"

type RawCodec struct {
	ParentCodec   encoding.Codec
	unmarshalFunc func([]byte, interface{}) error
}

func (c *RawCodec) Name() string {
	return RawCodecName
}

func (c *RawCodec) Marshal(v interface{}) ([]byte, error) {
	if rawBytes, ok := v.([]byte); ok {
		return rawBytes, nil
	}
	// If type is not []byte, we don't know how to handle it.
	/*
		if _, ok := v.(*podservice.Empty); !ok {
			klog.Infof("Warning: RawCodec received non-[]byte value: %T", v)
		}
	*/
	return c.ParentCodec.Marshal(v)
}

func (c *RawCodec) Unmarshal(data []byte, v interface{}) error {
	if c.unmarshalFunc != nil {
		return c.unmarshalFunc(data, v)
	}
	return c.ParentCodec.Unmarshal(data, v)
}
