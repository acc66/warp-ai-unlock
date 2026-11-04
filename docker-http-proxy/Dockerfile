FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY proxy.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -mod=mod -trimpath -ldflags="-s -w" -o /proxy ./proxy.go
FROM alpine:3.21
COPY --from=build /proxy /usr/local/bin/proxy
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/proxy"]
