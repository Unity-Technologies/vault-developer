FROM vault:latest

ADD . /tmp/

RUN /tmp/setup.sh

ENV SKIP_SETCAP=1
ENV VAULT_ADDR=http://0.0.0.0:8200

ENTRYPOINT ["/opt/run.sh"]
CMD ["server", "-dev"]
HEALTHCHECK --interval=5s --timeout=2s \
  CMD [[ -f /opt/healthcheck ]]
