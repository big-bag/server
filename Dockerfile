ARG ALPINE_VERSION=3.17.2 \
    ANSIBLE_CORE_VERSION=2.14.2 \
    ONE_PASSWORD_CLI_VERSION=2.14.0 \
    ONE_PASSWORD_CLI_ARCH=arm64

FROM alpine:$ALPINE_VERSION
ARG ANSIBLE_CORE_VERSION \
    ONE_PASSWORD_CLI_VERSION \
    ONE_PASSWORD_CLI_ARCH
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
# https://developer.1password.com/docs/cli/get-started
RUN wget https://cache.agilebits.com/dist/1P/op2/pkg/v${ONE_PASSWORD_CLI_VERSION}/op_linux_${ONE_PASSWORD_CLI_ARCH}_v${ONE_PASSWORD_CLI_VERSION}.zip -O op.zip && \
    unzip -d op op.zip

FROM alpine:$ALPINE_VERSION
ARG USER=ansible \
    GROUP=ansible \
    UID=1000 \
    GID=1000
COPY --from=0 /usr/bin/ansible* /usr/bin/
COPY --from=0 /usr/lib/python3.10/site-packages/ /usr/lib/python3.10/site-packages/
COPY --from=0 /op/op /usr/bin/
RUN apk add --update --no-cache \
      python3 \
      py3-pip \
      sshpass \
      openssh-client \
      git \
      rsync && \
    \
    addgroup -g $GID $GROUP && \
    adduser -h /home/$USER -s /bin/sh -G $GROUP -D -u $UID $USER && \
    \
    apk add --update --no-cache sudo && \
    echo "$USER ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER && \
    chmod 0440 /etc/sudoers.d/$USER
RUN python3 -m compileall /usr/lib/python3.10/
RUN python3 -m pip install jmespath==1.0.1
USER $USER
RUN ansible-galaxy collection install \
      community.general \
      community.crypto \
      ansible.posix
ENV ANSIBLE_VAULT_PASSWORD_FILE=.vault_password \
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_INVENTORY=hosts
WORKDIR /etc/ansible
