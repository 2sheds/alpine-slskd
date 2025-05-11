# build static web content
# note: pin this to amd64 to speed it up, it is prohibitively slow under QEMU
FROM --platform=$BUILDPLATFORM node:24-alpine3.20 AS web
ARG VERSION=0.0.1.65534-local

# Set working directory
WORKDIR /slskd

RUN apk add --no-cache git \
	&& git clone https://github.com/slskd/slskd.git . \
	&& sh ./bin/build --web-only --version $VERSION

# build, test, and publish application binaries
# note: this needs to be pinned to an amd64 image in order to publish armv7 binaries
# https://github.com/dotnet/dotnet-docker/issues/1537#issuecomment-615269150
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:8.0-alpine3.20 AS publish
ARG TARGETPLATFORM
ARG VERSION=0.0.1.65534-local

COPY --from=web /slskd /slskd/.

# Set working directory
WORKDIR /slskd

# Build the application
RUN sh ./bin/build --dotnet-only --version $VERSION \
    && dotnet publish --configuration Release \
	   -p:PublishSingleFile=true \
	   -p:ReadyToRun=true \
      -p:IncludeNativeLibrariesForSelfExtract=true \
      -p:CopyOutputSymbolsToPublishDirectory=false \
      --self-contained \
      --runtime ${TARGETPLATFORM} \
      --output ../../dist/${TARGETPLATFORM} \
	&& cd ../../dist/${TARGETPLATFORM} \
	&& ls -la .

# Stage 3: runtime for running the application
FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-alpine3.20 AS slskd
ARG TARGETPLATFORM
ARG TAG=0.0.1
ARG VERSION=0.0.1.65534-local
ARG REVISION=0
ARG BUILD_DATE

ENV DOTNET_EnableDiagnostics=0 \
  DOTNET_BUNDLE_EXTRACT_BASE_DIR=/.net \
  DOTNET_gcServer=0 \
  DOTNET_gcConcurrent=1 \
  DOTNET_GCHeapHardLimit=1F400000	\
  DOTNET_GCConserveMemory=9 \
  SLSKD_UMASK=0022 \
  SLSKD_HTTP_PORT=5030 \
  SLSKD_HTTPS_PORT=5031 \
  SLSKD_SLSK_LISTEN_PORT=50300 \
  SLSKD_APP_DIR=/app \
  SLSKD_DOCKER_TAG=$TAG \
  SLSKD_DOCKER_VERSION=$VERSION \
  SLSKD_DOCKER_REVISON=$REVISION \
  SLSKD_DOCKER_BUILD_DATE=$BUILD_DATE

LABEL org.opencontainers.image.title=slskd \
  org.opencontainers.image.description="A modern client-server application for the Soulseek file sharing network" \
  org.opencontainers.image.authors="Oleg Kurapov" \
  org.opencontainers.image.vendor="Oleg Kurapov" \
  org.opencontainers.image.licenses=AGPL-3.0 \
  org.opencontainers.image.url=https://github.com/2sheds/alpine-slskd \
  org.opencontainers.image.source=https://github.com/slskd/slskd \
  org.opencontainers.image.documentation=https://github.com/slskd/slskd \
  org.opencontainers.image.version=$VERSION \
  org.opencontainers.image.revision=$REVISION \
  org.opencontainers.image.created=$BUILD_DATE

# Set working directory
WORKDIR /slskd

RUN apk add --no-cache jq tini \
	&& mkdir -p /app/incomplete /app/downloads \
	&& mkdir -p /.net \
	&& chmod 777 /.net \
	&& echo -e "#!/bin/sh\numask \$SLSKD_UMASK && ./slskd" > start.sh \
    && chmod +x start.sh

VOLUME /app

HEALTHCHECK --interval=60s --timeout=3s --start-period=5s --retries=3 CMD wget -q -O - http://localhost:${SLSKD_HTTP_PORT}/health

# Copy the built application from the publish stage
COPY --from=publish /slskd/dist/${TARGETPLATFORM} .

# Expose the port the app runs on
EXPOSE 5030
EXPOSE 5031
EXPOSE 50300

# Command to run the application
ENTRYPOINT ["/sbin/tini", "--", "./start.sh"]
