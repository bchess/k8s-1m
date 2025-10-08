// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package webhook

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/klog/v2"
)

type WebhookServer struct {
	server   *http.Server
	podQueue chan<- *corev1.Pod
	addr     string
}

func NewWebhookServer(addr string, podQueue chan<- *corev1.Pod) *WebhookServer {
	return &WebhookServer{
		addr:     addr,
		podQueue: podQueue,
	}
}

func (ws *WebhookServer) Start() error {
	// Load TLS certificates
	certPath := filepath.Join("/etc/webhook/certs", "tls.crt")
	keyPath := filepath.Join("/etc/webhook/certs", "tls.key")

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return fmt.Errorf("failed to load TLS certificates: %v", err)
	}

	// Create TLS config
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	// Create HTTP server
	ws.server = &http.Server{
		Addr:      ws.addr,
		TLSConfig: tlsConfig,
		Handler:   http.HandlerFunc(ws.handleWebhook),
	}

	// Start server
	klog.Info("Starting webhook server on ", ws.addr)
	listener, err := net.Listen("tcp", ws.addr)
	if err != nil {
		return fmt.Errorf("failed to listen: %v", err)
	}
	return ws.server.ServeTLS(listener, "", "")
}

func (ws *WebhookServer) Stop() error {
	if ws.server != nil {
		return ws.server.Close()
	}
	return nil
}

func (ws *WebhookServer) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/validate" {
		http.Error(w, "Not found", http.StatusNotFound)
		r.Body.Close()
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Not found", http.StatusMethodNotAllowed)
		r.Body.Close()
		return
	}

	body, err := io.ReadAll(r.Body)
	// Close ASAP so we can reuse the connection
	r.Body.Close()
	if err != nil {
		klog.Error(err, "Failed to read request body")
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}

	// Parse admission request
	var admissionReview admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		klog.Error(err, "Failed to parse admission request")
		http.Error(w, "Failed to parse admission request", http.StatusBadRequest)
		return
	}
	rawBytes := admissionReview.Request.Object.Raw

	// Create admission response - always allow
	admissionResponse := &admissionv1.AdmissionResponse{
		UID:     admissionReview.Request.UID,
		Allowed: true,
	}

	// Send response ASAP
	admissionReview.Response = admissionResponse
	admissionReview.Request = nil
	json.NewEncoder(w).Encode(admissionReview)

	var pod corev1.Pod
	if err := json.Unmarshal(rawBytes, &pod); err != nil {
		klog.Error(err, "Failed to parse pod from request")
		http.Error(w, "Failed to parse pod from request", http.StatusBadRequest)
		return
	}

	// Only queue pods that use our scheduler
	if pod.Name[len(pod.Name)-1] == '0' && pod.Name[len(pod.Name)-2] == '0' {
		klog.Info("AdmissionReview for pod ", pod.Name, " using scheduler ", pod.Spec.SchedulerName)
	}
	if pod.Spec.SchedulerName == "dist-scheduler" {
		ws.podQueue <- &pod
	}
}
