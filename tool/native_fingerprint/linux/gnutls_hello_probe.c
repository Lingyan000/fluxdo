// 仅验证本机 GnuTLS 可表达的 ClientHello；不联网，不是生产 TLS 后端。
#include <gnutls/gnutls.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
static ssize_t sink(gnutls_transport_ptr_t p,const void *data,size_t n){return fwrite(data,1,n,(FILE*)p);}
static ssize_t wait_input(gnutls_transport_ptr_t p,void *data,size_t n){(void)p;(void)data;(void)n;errno=EAGAIN;return -1;}
int main(int argc,char**argv){
 if(argc!=3)return 2;
 gnutls_session_t s;gnutls_certificate_credentials_t creds;
 if(gnutls_global_init()<0 || gnutls_init(&s,GNUTLS_CLIENT|GNUTLS_NONBLOCK)<0)return 3;
 gnutls_certificate_allocate_credentials(&creds);gnutls_credentials_set(s,GNUTLS_CRD_CERTIFICATE,creds);
 const char*error=NULL;int r=gnutls_priority_set_direct(s,argv[1],&error);if(r<0){fprintf(stderr,"priority: %s at %s\n",gnutls_strerror(r),error);return 4;}
 gnutls_server_name_set(s,GNUTLS_NAME_DNS,"localhost",9);
 gnutls_datum_t alpn[]={{(unsigned char*)"h2",2},{(unsigned char*)"http/1.1",8}};gnutls_alpn_set_protocols(s,alpn,2,0);
 FILE*out=fopen(argv[2],"wb");if(!out)return 5;
 gnutls_transport_set_ptr(s,out);gnutls_transport_set_push_function(s,sink);gnutls_transport_set_pull_function(s,wait_input);
 r=gnutls_handshake(s);fprintf(stderr,"version=%s result=%s\n",gnutls_check_version(NULL),gnutls_strerror(r));
 fclose(out);gnutls_deinit(s);gnutls_certificate_free_credentials(creds);gnutls_global_deinit();return r==GNUTLS_E_AGAIN?0:6;
}
