ARG ALPINE_VERSION=3.16.3
ARG ANSIBLE_CORE_VERSION=2.14.0

FROM alpine:$ALPINE_VERSION
ARG USER=ansible \
    GROUP=ansible \
    UID=1000 \
    GID=1000 \
    ANSIBLE_CORE_VERSION
RUN apk add --update --no-cache python3 py3-pip
RUN addgroup -g $GID $GROUP && \
    adduser -h /home/$USER -s /bin/sh -G $GROUP -D -u $UID $USER && \
    \
    apk add --update --no-cache sudo && \
    echo "$USER ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER && \
    chmod 0440 /etc/sudoers.d/$USER
USER $USER
RUN python3 -m pip install ansible-core==$ANSIBLE_CORE_VERSION && \
    find /usr/lib/ -name '__pycache__' -print0 | xargs -0 -n1 sudo rm -rf
ENV PATH=$PATH:/home/$USER/.local/bin
WORKDIR /etc/ansible
