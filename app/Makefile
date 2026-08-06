IMAGE ?= ghcr.io/c4geeks/rollouts-demo
PLATFORM ?= linux/amd64

.PHONY: push
push:  ## Build and push v1 (blue, healthy), v2 (green, healthy), v3 (red, 10% 5xx)
	docker buildx build --platform $(PLATFORM) --build-arg VERSION=v1 --build-arg COLOR='#2563eb' --build-arg ERROR_RATE=0  -t $(IMAGE):v1 --push .
	docker buildx build --platform $(PLATFORM) --build-arg VERSION=v2 --build-arg COLOR='#16a34a' --build-arg ERROR_RATE=0  -t $(IMAGE):v2 --push .
	docker buildx build --platform $(PLATFORM) --build-arg VERSION=v3 --build-arg COLOR='#dc2626' --build-arg ERROR_RATE=10 -t $(IMAGE):v3 --push .
