# Stage 1: build the Flutter web bundle
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY scripts/stamp-web.sh /tmp/stamp-web.sh
COPY app/ ./
RUN flutter build web --release && sh /tmp/stamp-web.sh /src/app/build/web

# Stage 2: build the Go server with the web bundle embedded
FROM golang:1.27-alpine AS server
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
COPY --from=web /src/app/build/web/ ./internal/web/dist/
RUN CGO_ENABLED=0 go build -o /out/dusty ./cmd/dusty

# Stage 3: minimal runtime
FROM alpine:3.20
RUN adduser -D -H dusty && mkdir -p /data && chown dusty /data
COPY --from=server /out/dusty /usr/local/bin/dusty
USER dusty
ENV DUSTY_ADDR=:8080 DUSTY_DATA_DIR=/data
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["dusty"]
