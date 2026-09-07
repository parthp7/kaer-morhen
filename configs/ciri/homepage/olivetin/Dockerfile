# OliveTin + the two tools its actions need. Base is Fedora (microdnf).
# Bump the tag here on upgrade, then: docker compose build --pull && up -d
FROM docker.io/jamesread/olivetin:3000.19.0
# The base image ends with `USER olivetin` (uid 1000, created with a home dir),
# so package installs must switch to root and hand back to the same user —
# without the final USER line the container would run as root.
USER root
RUN microdnf install -y openssh-clients jq && microdnf clean all
USER olivetin
