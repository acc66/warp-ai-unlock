package main
import (
"context"
"crypto/subtle"
"encoding/base64"
"io"
"log"
"net"
"net/http"
"os"
"strings"
"time"
"golang.org/x/net/proxy"
)
func main(){
 user,pass:=os.Getenv("PROXY_USER"),os.Getenv("PROXY_PASS")
 if user==""||pass=="" {log.Fatal("PROXY_USER and PROXY_PASS required")}
 socks:=os.Getenv("SOCKS_ADDR");if socks==""{socks="warp:1080"}
 addr:=os.Getenv("LISTEN_ADDR");if addr==""{addr=":8080"}
 dialer,err:=proxy.SOCKS5("tcp",socks,nil,&net.Dialer{Timeout:10*time.Second});if err!=nil{log.Fatal(err)}
 dial:=func(ctx context.Context,network,address string)(net.Conn,error){return dialer.Dial("tcp",address)}
 tr:=&http.Transport{Proxy:nil,DialContext:dial,ForceAttemptHTTP2:false,DisableKeepAlives:true,ResponseHeaderTimeout:30*time.Second}
 handler:=http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  expected:="Basic "+base64.StdEncoding.EncodeToString([]byte(user+":"+pass))
  supplied:=r.Header.Get("Proxy-Authorization")
  if subtle.ConstantTimeCompare([]byte(supplied),[]byte(expected))!=1 {w.Header().Set("Proxy-Authenticate",`Basic realm="WARP"`);http.Error(w,"proxy authentication required",http.StatusProxyAuthRequired);return}
  if r.Method==http.MethodConnect {
   target:=r.Host;if _,_,e:=net.SplitHostPort(target);e!=nil{http.Error(w,"CONNECT requires host:port",400);return}
   upstream,e:=dial(r.Context(),"tcp",target);if e!=nil{http.Error(w,"WARP upstream unavailable",502);return}
   hijacker,ok:=w.(http.Hijacker);if !ok{upstream.Close();http.Error(w,"hijack unsupported",500);return}
   client,buf,e:=hijacker.Hijack();if e!=nil{upstream.Close();return}
   _,e=buf.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n");if e==nil{e=buf.Flush()};if e!=nil{client.Close();upstream.Close();return}
   go func(){defer client.Close();defer upstream.Close();io.Copy(upstream,buf)}()
   go func(){defer client.Close();defer upstream.Close();io.Copy(client,upstream)}()
   return
  }
  if r.URL.Scheme!="http"||r.URL.Host==""{http.Error(w,"absolute http URL required",400);return}
  outbound:=r.Clone(r.Context());outbound.RequestURI="";outbound.Header.Del("Proxy-Authorization");outbound.Header.Del("Proxy-Connection");outbound.Header.Del("Connection")
  resp,e:=tr.RoundTrip(outbound);if e!=nil{http.Error(w,"WARP upstream unavailable",502);return};defer resp.Body.Close()
  for k,values:=range resp.Header{if strings.EqualFold(k,"Connection")||strings.EqualFold(k,"Transfer-Encoding"){continue};for _,v:=range values{w.Header().Add(k,v)}}
  w.WriteHeader(resp.StatusCode);io.Copy(w,resp.Body)
 })
 server:=&http.Server{Addr:addr,Handler:handler,ReadHeaderTimeout:10*time.Second,IdleTimeout:60*time.Second}
 log.Printf("HTTP proxy listening on %s; SOCKS upstream %s",addr,socks);log.Fatal(server.ListenAndServe())
}
