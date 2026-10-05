# Stage 1: build the Flutter web bundle.
# The Cirrus stable image stopped at Dart 3.12. The app requires Dart ^3.13.4
# (Flutter 3.47), so the matching SDK is cloned on top of that image.
FROM ghcr.io/cirruslabs/flutter:stable AS web
RUN git clone --depth 1 --branch 3.47.6 https://github.com/flutter/flutter.git /opt/flutter \
 && git config --global --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}" \
    CI=true \
    FLUTTER_HOME=/opt/flutter \
    FLUTTER_ROOT=/opt/flutter
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
