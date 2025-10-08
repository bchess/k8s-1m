/*
Copyright 2025 Benjamin Chess

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"
	"sync"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/flowcontrol"
)

var numClientSets = 10

func getSchedulerPods(clientset *kubernetes.Clientset) ([]string, error) {
	selector := labels.Set{
		"app":  "dist-scheduler",
		"role": "scheduler",
	}.AsSelector()

	pods, err := clientset.CoreV1().Pods("kube-system").List(context.TODO(), metav1.ListOptions{
		LabelSelector: selector.String(),
	})
	if err != nil {
		return nil, fmt.Errorf("error listing scheduler pods: %v", err)
	}

	podNames := make([]string, 0, len(pods.Items))
	for _, pod := range pods.Items {
		podNames = append(podNames, pod.Name)
	}

	return podNames, nil
}

func main() {
	skip := flag.Int("skip", 0, "Skip creating the first N nodes")
	numNodes := flag.Int("count", 1, "Number of nodes to create")
	kubeconfig := flag.String("kubeconfig", "", "Path to the kubeconfig file (optional)")
	ppn := flag.Int("podsPerNode", 32, "Pod capacity per node")
	perKwokGroup := flag.Int("perKwokGroup", 10000, "Nodes per kwok group")
	flag.Parse()

	config, err := buildConfig(*kubeconfig)
	if err != nil {
		log.Fatalf("Error building kubeconfig: %v", err)
	}
	config.RateLimiter = flowcontrol.NewFakeAlwaysRateLimiter()

	clientsets := make([]*kubernetes.Clientset, numClientSets)
	for i := 0; i < numClientSets; i++ {
		clientsets[i], err = kubernetes.NewForConfig(config)
		if err != nil {
			log.Fatalf("Error creating Kubernetes client: %v", err)
		}
	}

	// Get scheduler pods using the first clientset
	schedulerPodNames, err := getSchedulerPods(clientsets[0])
	if err != nil {
		log.Printf("Error getting scheduler pods: %v\n", err)
	}

	// Limit concurrency to 100
	sem := make(chan struct{}, 100*numClientSets)

	// WaitGroup to wait for all creations
	var wg sync.WaitGroup
	wg.Add(*numNodes - *skip)

	podsPerNode := resource.MustParse(fmt.Sprintf("%d", *ppn))

	for i := *skip; i < *numNodes; i++ {
		i := i
		// Acquire a token
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			err := createNode(clientsets[i%numClientSets], i, *perKwokGroup, podsPerNode, schedulerPodNames)
			if err != nil {
				log.Printf("Error handling node %d: %v", i, err)
			}
		}()
	}

	// Wait for all goroutines to finish
	wg.Wait()
	fmt.Println("All nodes created.")
}

func createNode(clientset *kubernetes.Clientset, index int, perKwokGroup int, podsPerNode resource.Quantity, schedulerPodNames []string) error {
	nodeName := fmt.Sprintf("kwok-node-%d", index)

	// This is optional but will speed up a test so that the nodes already have the scheduler label assigned
	// Otherwise the leader scheduler will do it itself.
	var schedulerName string
	if len(schedulerPodNames) > 0 {
		schedulerName = schedulerPodNames[index%len(schedulerPodNames)]
	}

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: nodeName,
			Annotations: map[string]string{
				"node.alpha.kubernetes.io/ttl": "300",
				"kwok.x-k8s.io/node":           "fake",
			},
			Labels: map[string]string{
				"beta.kubernetes.io/arch":       "amd64",
				"beta.kubernetes.io/os":         "linux",
				"kubernetes.io/arch":            "amd64",
				"kubernetes.io/hostname":        nodeName,
				"kubernetes.io/os":              "linux",
				"kubernetes.io/role":            "agent",
				"node-role.kubernetes.io/agent": "",
				"type":                          "kwok",
				"kwok-group":                    strconv.Itoa(index / perKwokGroup),
				"dist-scheduler.dev/scheduler":  schedulerName,
			},
			Finalizers: []string{
				"wrangler.cattle.io/node",
			},
		},
		Spec: corev1.NodeSpec{
			Taints: []corev1.Taint{
				{
					Key:    "kwok.x-k8s.io/node",
					Value:  "fake",
					Effect: corev1.TaintEffectNoSchedule,
				},
			},
		},
		Status: corev1.NodeStatus{
			Allocatable: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("32"),
				corev1.ResourceMemory: resource.MustParse("256Gi"),
				corev1.ResourcePods:   podsPerNode,
			},
			Capacity: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("32"),
				corev1.ResourceMemory: resource.MustParse("256Gi"),
				corev1.ResourcePods:   podsPerNode,
			},
			NodeInfo: corev1.NodeSystemInfo{
				Architecture:            "amd64",
				BootID:                  "",
				ContainerRuntimeVersion: "",
				KernelVersion:           "",
				KubeProxyVersion:        "fake",
				KubeletVersion:          "fake",
				MachineID:               "",
				OperatingSystem:         "linux",
				SystemUUID:              "",
			},
			Phase: corev1.NodeRunning,
		},
	}

	fmt.Printf("Creating node %s...\n", nodeName)
	_, err := clientset.CoreV1().Nodes().Create(context.TODO(), node, metav1.CreateOptions{})
	if err != nil {
		return err
	} else {
		fmt.Printf("Node %s created successfully.\n", nodeName)
	}

	// Now attempt to set the status
	// Note: This may fail if the API server disallows setting node status.
	/*
		createdNode.Status = corev1.NodeStatus{
			Allocatable: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("32"),
				corev1.ResourceMemory: resource.MustParse("256Gi"),
				corev1.ResourcePods:   resource.MustParse("1024"),
			},
			Capacity: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("32"),
				corev1.ResourceMemory: resource.MustParse("256Gi"),
				corev1.ResourcePods:   resource.MustParse("1024"),
			},
			NodeInfo: corev1.NodeSystemInfo{
				Architecture:            "amd64",
				BootID:                  "",
				ContainerRuntimeVersion: "",
				KernelVersion:           "",
				KubeProxyVersion:        "fake",
				KubeletVersion:          "fake",
				MachineID:               "",
				OperatingSystem:         "linux",
				SystemUUID:              "",
			},
			Phase: corev1.NodeRunning,
		}

		// Use UpdateStatus subresource
		_, err = clientset.CoreV1().Nodes().UpdateStatus(context.TODO(), createdNode, metav1.UpdateOptions{})
		if err != nil {
			return fmt.Errorf("error updating node status %s: %w", nodeName, err)
		}
		fmt.Printf("Node %s status updated successfully.\n", nodeName)
	*/
	return nil
}

func buildConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig != "" {
		config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err == nil {
			return config, nil
		}
		return nil, err
	}
	// In-cluster config
	config, err := rest.InClusterConfig()
	if err == nil {
		return config, nil
	}
	// If no in-cluster config, try default config from home dir
	if home := os.Getenv("HOME"); home != "" {
		kubeconfigPath := home + "/.kube/config"
		config, err := clientcmd.BuildConfigFromFlags("", kubeconfigPath)
		if err == nil {
			return config, nil
		}
	}
	return nil, fmt.Errorf("could not create Kubernetes configuration")
}
