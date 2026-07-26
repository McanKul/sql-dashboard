FROM node:22-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
ARG VITE_API_BASE_URL=/api/v1
ARG VITE_DEMO_MODE=false
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
ENV VITE_DEMO_MODE=${VITE_DEMO_MODE}
RUN npm run build

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
COPY THIRD_PARTY_NOTICES.txt /usr/share/nginx/html/THIRD_PARTY_NOTICES.txt
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s --retries=5 CMD wget -q --spider http://127.0.0.1/healthz || exit 1
