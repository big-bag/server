ARG ALPINE_VERSION=3.18.2 \
    ANSIBLE_CORE_VERSION=2.15.1 \
    ONE_PASSWORD_CLI_VERSION=2.18.0 \
    ONE_PASSWORD_CLI_ARCH=arm64 \
    GOLANG_VERSION=1.21rc2-alpine3.18 \
    SSH_TO_AGE_VERSION=1.1.4 \
    SOPS_VERSION=3.7.3

FROM alpine:$ALPINE_VERSION
ARG ANSIBLE_CORE_VERSION
RUN apk add --update --no-cache \
      python3 \
      py3-pip \
      gcc \
      python3-dev \
      musl-dev \
      libffi-dev \
      py3-wheel
RUN python3 -m pip install ansible-core==$ANSIBLE_CORE_VERSION && \
    find /usr/lib/ -name '__pycache__' -print0 | xargs -0 -n1 rm -rf

FROM alpine:$ALPINE_VERSION
ARG ONE_PASSWORD_CLI_VERSION \
    ONE_PASSWORD_CLI_ARCH
# https://developer.1password.com/docs/cli/get-started
RUN wget https://cache.agilebits.com/dist/1P/op2/pkg/v${ONE_PASSWORD_CLI_VERSION}/op_linux_${ONE_PASSWORD_CLI_ARCH}_v${ONE_PASSWORD_CLI_VERSION}.zip -O op.zip && \
    unzip -d op op.zip

FROM golang:$GOLANG_VERSION
ARG SSH_TO_AGE_VERSION
ADD https://github.com/Mic92/ssh-to-age/archive/refs/tags/$SSH_TO_AGE_VERSION.tar.gz $GOPATH/src/
RUN tar -zxvf $GOPATH/src/$SSH_TO_AGE_VERSION.tar.gz -C $GOPATH/src/
WORKDIR $GOPATH/src/ssh-to-age-$SSH_TO_AGE_VERSION/cmd/ssh-to-age
RUN go build -o $GOPATH/bin/

FROM golang:$GOLANG_VERSION
ARG SOPS_VERSION
ADD https://github.com/mozilla/sops/archive/refs/tags/v$SOPS_VERSION.tar.gz $GOPATH/src/go.mozilla.org/
RUN tar -zxvf $GOPATH/src/go.mozilla.org/v$SOPS_VERSION.tar.gz -C $GOPATH/src/go.mozilla.org/ && \
    apk add --update --no-cache \
      make \
      gcc \
      musl-dev
WORKDIR $GOPATH/src/go.mozilla.org/sops-$SOPS_VERSION
ENV CGO_ENABLED=1
RUN make install

FROM alpine:$ALPINE_VERSION
ARG USER=ansible \
    GROUP=ansible \
    UID=1000 \
    GID=1000
COPY --from=0 /usr/bin/ansible* /usr/bin/
COPY --from=0 /usr/lib/python3.11/site-packages/ /usr/lib/python3.11/site-packages/
COPY --from=1 /op/op /usr/bin/
COPY --from=2 /go/bin/ssh-to-age /usr/bin/
COPY --from=3 /go/bin/sops /usr/bin/
RUN apk add --update --no-cache \
      python3 \
      py3-pip \
      sshpass \
      openssh-client \
      age \
      git \
      curl \
      jq \
      rsync && \
    \
    addgroup -g $GID $GROUP && \
    adduser -h /home/$USER -s /bin/sh -G $GROUP -D -u $UID $USER && \
    \
    apk add --update --no-cache sudo && \
    echo "$USER ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER && \
    chmod 0440 /etc/sudoers.d/$USER
RUN python3 -m compileall /usr/lib/python3.11/
RUN python3 -m pip install \
      jmespath==1.0.1 \
      passlib==1.7.4
USER $USER
RUN ansible-galaxy collection install \
      community.general \
      community.crypto \
      ansible.posix
ENV ANSIBLE_VAULT_PASSWORD_FILE=.vault_password \
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_INVENTORY=hosts \
    SOPS_AGE_KEY_FILE=configs/key.txt
WORKDIR /etc/ansible
