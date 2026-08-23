Change TCP options macro definitions to those currently used by Linux
for compatibility with socket syscalls.

diff --git a/src/include/lwip/sockets.h b/src/include/lwip/sockets.h
--- a/src/include/lwip/sockets.h	2023-04-15 19:02:41.486964340 +0300
+++ b/src/include/lwip/sockets.h	2023-04-15 19:06:11.337323112 +0300
@@ -60,9 +60,9 @@
  */
 #define TCP_NODELAY    0x01    /* don't delay send to coalesce packets */
 #define TCP_KEEPALIVE  0x02    /* send KEEPALIVE probes when idle for pcb->keep_idle milliseconds */
-#define TCP_KEEPIDLE   0x03    /* set pcb->keep_idle  - Same as TCP_KEEPALIVE, but use seconds for get/setsockopt */
-#define TCP_KEEPINTVL  0x04    /* set pcb->keep_intvl - Use seconds for get/setsockopt */
-#define TCP_KEEPCNT    0x05    /* set pcb->keep_cnt   - Use number of probes sent for get/setsockopt */
+#define TCP_KEEPIDLE   0x04    /* set pcb->keep_idle  - Same as TCP_KEEPALIVE, but use seconds for get/setsockopt */
+#define TCP_KEEPINTVL  0x05    /* set pcb->keep_intvl - Use seconds for get/setsockopt */
+#define TCP_KEEPCNT    0x06    /* set pcb->keep_cnt   - Use number of probes sent for get/setsockopt */
 #endif /* LWIP_TCP */
 
 /* FD_SET used for lwip_select */
