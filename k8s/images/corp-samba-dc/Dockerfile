FROM alpine:3.22
RUN apk add --no-cache samba-dc samba-client py3-cryptography py3-setproctitle krb5 openldap-clients bind-tools tini \
 && rm -f /etc/samba/smb.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
VOLUME ["/var/lib/samba"]
EXPOSE 53/udp 53 88/udp 88 135 139 389/udp 389 445 464/udp 464 636 3268 3269
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
