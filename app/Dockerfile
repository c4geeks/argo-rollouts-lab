# BUILDPLATFORM keeps the Go toolchain running natively on the build host and
# cross-compiles to TARGETARCH. Without it, an amd64 build on an arm64 Mac runs
# the whole compile under qemu emulation and takes minutes instead of seconds.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG COLOR=#2563eb
ARG ERROR_RATE=0
ARG LATENCY_MS=0

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath \
      -ldflags="-s -w \
        -X main.version=${VERSION} \
        -X main.color=${COLOR} \
        -X main.defaultErrorRate=${ERROR_RATE} \
        -X main.defaultLatencyMs=${LATENCY_MS}" \
      -o /out/demo .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/demo /demo
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/demo"]
