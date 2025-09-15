FROM alpine:3.20

# bash, cron, dig, jq, curl, tzdata
RUN apk add --no-cache bash busybox-suid bind-tools jq curl tzdata

WORKDIR /app
COPY docker/update-whitelists.sh /app/update-whitelists.sh
COPY docker/entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/*.sh

ENV TZ=Europe/Zurich
ENV RUN_EVERY="*/5 * * * *"

ENTRYPOINT ["/app/entrypoint.sh"]