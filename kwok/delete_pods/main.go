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
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/flowcontrol"
)

var numClientSets = 10

func main() {
	skip := flag.Int("skip", 0, "Skip creating the first N resources")
	numResources := flag.Int("count", 1, "Number of resources to create")
	kubeconfig := flag.String("kubeconfig", "", "Path to the kubeconfig file (optional)")
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

	// Limit concurrency to 100*10
	sem := make(chan struct{}, 100*numClientSets)

	// WaitGroup to wait for all creations
	var wg sync.WaitGroup
	wg.Add(*numResources)

	for i := *skip; i < *numResources; i++ {
		// Acquire a token
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			err := deleteResource(clientsets[i%numClientSets], i)
			if err != nil {
				log.Printf("Error handling resource %d: %v", i, err)
			}
		}()
	}

	// Wait for all goroutines to finish
	wg.Wait()
	fmt.Println("All resources deleted.")
}

func deleteResource(clientset *kubernetes.Clientset, index int) error {
	resourceName := fmt.Sprintf("res-%d", index)

	fmt.Printf("Creating %s...\n", resourceName)
	err := clientset.CoreV1().Pods(metav1.NamespaceDefault).Delete(context.TODO(), resourceName, metav1.DeleteOptions{})
	if err != nil {
		return err
	} else {
		fmt.Printf("%s deleted.\n", resourceName)
	}

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
