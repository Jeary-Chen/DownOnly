# 第一阶段：编译
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod init downonly || true
RUN go mod tidy
RUN go build -ldflags="-s -w" -o downonly main.go

# 第二阶段：运行
FROM alpine:latest
WORKDIR /app
# 复制编译好的二进制文件
COPY --from=builder /app/downonly .
# 复制前端文件
COPY --from=builder /app/index.html .

# 创建数据目录
RUN mkdir -p /app/data

# 开放 8080 端口
EXPOSE 8080

# 运行命令
ENTRYPOINT ["./downonly"]
