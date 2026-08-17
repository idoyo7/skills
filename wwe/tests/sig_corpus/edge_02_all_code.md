# 배포 스크립트 모음

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${1:?app name required}"
ENV="${2:-staging}"

echo "deploying ${APP_NAME} to ${ENV}"

kubectl config use-context "${ENV}-cluster"
kubectl set image deployment/"${APP_NAME}" \
  "${APP_NAME}=registry.internal/${APP_NAME}:$(git rev-parse --short HEAD)" \
  -n "${APP_NAME}"

kubectl rollout status deployment/"${APP_NAME}" -n "${APP_NAME}" --timeout=120s
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  namespace: sample-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
        - name: sample-app
          image: registry.internal/sample-app:latest
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

```bash
# 롤백용
kubectl rollout undo deployment/sample-app -n sample-app
```

```dockerfile
FROM node:22-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-slim
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
CMD ["node", "dist/index.js"]
```

위 스크립트는 배포용 도구 모음이다. 필요할 때 복사해서 쓴다.
