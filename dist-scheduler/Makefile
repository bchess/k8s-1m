all: dist-scheduler

DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

MANIFEST=docker.io/bchess/dist-scheduler:v5

PKG_FILES = $(shell find pkg/ -type f -name '*.go')
FORK_FILES = $(shell find fork/kubernetes/pkg -type f -name '*.go')
dist-scheduler: pkg/podservice/pod_grpc.pb.go pkg/podservice/pod.pb.go $(wildcard cmd/dist-scheduler/*.go) $(PKG_FILES) .vendor
	go build bchess.org/dist-scheduler/cmd/dist-scheduler

pkg/podservice/pod_grpc.pb.go pkg/podservice/pod.pb.go: .vendor proto/pod.proto
	protoc --go_out=pkg/podservice --go_opt=paths=source_relative --go-grpc_out=pkg/podservice --go-grpc_opt=paths=source_relative -I vendor -I proto proto/pod.proto

.vendor: go.mod $(FORK_FILES)
	go mod vendor && touch .vendor

.PHONY: docker buildah buildah-amd64
docker buildah: buildah-amd64
	buildah push $(MANIFEST):latest

buildah-amd64: .gocache/amd64 .gocache/mod manifest .vendor
	buildah build --platform linux/amd64 --layers --volume ${DIR}/.gocache/amd64:/gocache --volume ${DIR}/.gocache/mod:/gocachemod --volume ${DIR}/fork:/src/fork --manifest $(MANIFEST) .

.PHONY: buildah-arm
buildah-arm: .gocache/arm .gocache/mod manifest .vendor
	buildah build --platform linux/arm64 --layers --volume ${DIR}/.gocache/arm:/gocache --volume ${DIR}/.gocache/mod:/gocachemod --volume ${DIR}/fork:/src/fork --manifest $(MANIFEST) .

.gocache/arm:
	mkdir -p .gocache/arm
.gocache/mod:
	mkdir -p .gocache/mod
.gocache/amd64:
	mkdir -p .gocache/amd64


.PHONY: manifest
manifest:
	(podman manifest rm $(MANIFEST) || true) && podman manifest create $(MANIFEST)

.PHONY: docker-full buildah-full
docker-full buildah-full: buildah-amd64 buildah-arm
	podman manifest push $(MANIFEST) $(MANIFEST)
