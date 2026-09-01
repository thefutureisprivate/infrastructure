ARG MAIL_POSTGRES_BASE
FROM ${MAIL_POSTGRES_BASE}

# Exact Alpine package versions make the controller-built backup image
# reproducible and prevent a deployment from silently changing its toolchain.
RUN apk add --no-cache \
      age=1.3.1-r5 \
      coreutils=9.11-r0 \
      jq=1.8.1-r0 \
      openssl=3.5.8-r0 \
      pgbackrest=2.58.0-r0 \
      rclone=1.74.1-r1
