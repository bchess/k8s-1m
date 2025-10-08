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
	"net/http"
	"net/url"
	"os"
	"sync"
	"sync/atomic"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/flowcontrol"
)

var numClientSets = 12

func main() {
	skip := flag.Int("skip", 0, "Skip creating the first N resources")
	numResources := flag.Int("count", 1, "Number of resources to create")
	kubeconfig := flag.String("kubeconfig", "", "Path to the kubeconfig file (optional)")
	schedulerName := flag.String("scheduler-name", "dist-scheduler", "schedulerName. Default dist-scheduler")
	flag.Parse()

	errlog := log.New(os.Stderr, "", log.LstdFlags)

	config, err := buildConfig(*kubeconfig)
	if err != nil {
		log.Fatalf("Error building kubeconfig: %v", err)
	}
	config.RateLimiter = flowcontrol.NewFakeAlwaysRateLimiter()

	clientsets := make([]*kubernetes.Clientset, numClientSets)
	for i := 0; i < numClientSets; i++ {
		// This ensures that the transport is not shared between clientsets
		config.Proxy = func(req *http.Request) (*url.URL, error) {
			return nil, nil
		}
		clientsets[i], err = kubernetes.NewForConfig(config)
		if err != nil {
			log.Fatalf("Error creating Kubernetes client: %v", err)
		}
	}

	// WaitGroup to wait for all creations
	var wg sync.WaitGroup
	wg.Add(*numResources - *skip)

	ownerUid := types.UID("")
	if *skip == 0 {
		ownerUid, err = createResource(clientsets[0%numClientSets], 0, ownerUid, *schedulerName)
		if err != nil {
			errlog.Fatalf("Error creating resource: %v", err)
		}
		*skip = 1
		wg.Done()
	}

	start := int32(*skip) - 1
	end := int32(*skip+*numResources) - 1

	// Create worker pool
	numWorkers := 100 * numClientSets
	for w := 0; w < numWorkers; w++ {
		// log.Printf("Creating worker %d clientset %d", w, (w % numClientSets))
		go func(ww int) {
			cs := clientsets[ww%numClientSets]
			for {
				i := atomic.AddInt32(&start, 1)
				if i >= end {
					break
				}
				_, err := createResource(cs, int(i), ownerUid, *schedulerName)
				if err != nil {
					errlog.Printf("Error handling resource %d: %v", i, err)
				}
				wg.Done()
			}
		}(w)
	}

	// Wait for all work to complete
	wg.Wait()
	fmt.Println("All resources created.")
}

func createResource(clientset *kubernetes.Clientset, index int, uid types.UID, schedulerName string) (types.UID, error) {
	resourceName := fmt.Sprintf("res-%d", index)
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: resourceName,
			Labels: map[string]string{
				"app": "busybox",
			},
		},
		Spec: corev1.PodSpec{
			SchedulerName:                 schedulerName,
			TerminationGracePeriodSeconds: &[]int64{1}[0],
			Tolerations: []corev1.Toleration{
				{
					Key:      "kwok.x-k8s.io/node",
					Operator: corev1.TolerationOpExists,
					Effect:   corev1.TaintEffectNoSchedule,
				},
				{
					Key:      "node.kubernetes.io/not-ready",
					Operator: corev1.TolerationOpExists,
					Effect:   corev1.TaintEffectNoSchedule,
				},
				{
					Key:      "node.kubernetes.io/not-ready",
					Operator: corev1.TolerationOpExists,
					Effect:   corev1.TaintEffectNoExecute,
				},
			},
			Containers: []corev1.Container{
				{
					Name:            "busybox",
					Image:           "gcr.io/google-containers/busybox",
					ImagePullPolicy: corev1.PullIfNotPresent,
					Command: []string{
						"sleep",
						"99999",
					},
				},
			},
		},
	}
	if index != 0 && uid != "" {
		pod.OwnerReferences = []metav1.OwnerReference{
			{
				APIVersion: "v1",
				Kind:       "Pod",
				Name:       "res-0",
				UID:        uid,
			},
		}
	}

	fmt.Printf("Creating %s...\n", resourceName)
	pod, err := clientset.CoreV1().Pods(metav1.NamespaceDefault).Create(context.TODO(), pod, metav1.CreateOptions{})
	if err != nil {
		return "", err
	} else {
		fmt.Printf("%s created successfully.\n", resourceName)
	}

	uid = pod.ObjectMeta.UID
	return uid, nil
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
