ARG ALPINE_VERSION=3.16.3
ARG ANSIBLE_CORE_VERSION=2.14.0

FROM alpine:$ALPINE_VERSION
ARG USER=ansible \
    GROUP=ansible \
    UID=1000 \
    GID=1000 \
    ANSIBLE_CORE_VERSION
RUN apk add --update --no-cache \
      python3 \
      py3-pip \
      sshpass \
      openssh-client && \
    \
    addgroup -g $GID $GROUP && \
    adduser -h /home/$USER -s /bin/sh -G $GROUP -D -u $UID $USER && \
    \
    apk add --update --no-cache sudo && \
    echo "$USER ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER && \
    chmod 0440 /etc/sudoers.d/$USER && \
    \
    # https://developer.1password.com/docs/cli/get-started
    echo https://downloads.1password.com/linux/alpinelinux/stable/ >> /etc/apk/repositories && \
    wget https://downloads.1password.com/linux/keys/alpinelinux/support@1password.com-61ddfc31.rsa.pub -P /etc/apk/keys && \
    apk add --update --no-cache 1password-cli
USER $USER
RUN python3 -m pip install \
      ansible-core==$ANSIBLE_CORE_VERSION \
      jmespath==1.0.1 && \
    find /usr/lib/ -name '__pycache__' -print0 | xargs -0 -n1 sudo rm -rf
ENV PATH=$PATH:/home/$USER/.local/bin
RUN ansible-galaxy collection install \
      community.general \
      community.crypto
ENV ANSIBLE_VAULT_PASSWORD_FILE=.vault_password \
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_INVENTORY=hosts
WORKDIR /etc/ansible
