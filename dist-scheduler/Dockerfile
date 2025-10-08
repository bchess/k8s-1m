FROM docker.io/golang:1.23-alpine as builder
RUN apk add --no-cache make git protoc
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.5
RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
WORKDIR /src
COPY . .
ENV GOCACHE=/gocache
ENV GOMODCACHE=/gocachemod
RUN make dist-scheduler
FROM docker.io/alpine:3.20
COPY --from=builder /src/dist-scheduler /usr/local/bin/dist-scheduler

ENTRYPOINT ["dist-scheduler"]
