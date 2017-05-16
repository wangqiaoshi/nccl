/*************************************************************************
 * Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
 *
 * See LICENSE.txt for license information
 ************************************************************************/

#include "nccl.h"
#include "core.h"
#include "socket.h"
#include "net.h"
#include "topo.h"
#include "utils.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <sys/types.h>
#include <unistd.h>

//#include "infiniband/verbs.h"
#include "ibvwrap.h"

#define USE_RDMA_WRITE 1
#define MAX_IF_NAME_SIZE 16
#define MAXNAMESIZE 64
static char ncclIbIfName[MAX_IF_NAME_SIZE];
static union socketAddress ncclIbIfAddr;
static int ncclNIbDevs = -1;
struct ncclIbDev {
  int device;
  uint8_t port;
  ibv_context* context;
  char devPath[MAXPATHSIZE];
  char devName[MAXNAMESIZE];
};

#define MAX_IB_PORT 15
struct userIbDev {
  char devName[MAXNAMESIZE];
  uint16_t port_en;
};

#define MAX_IB_DEVS 16
struct ncclIbDev ncclIbDevs[MAX_IB_DEVS];
struct userIbDev userIbDevs[MAX_IB_DEVS];
int ncclIbTimeout = 14;
pthread_mutex_t ncclIbLock = PTHREAD_MUTEX_INITIALIZER;

pthread_t ncclIbAsyncThread;
static void* ncclIbAsyncThreadMain(void* args) {
  struct ibv_context* context = (struct ibv_context*)args;
  while (1) {
    struct ibv_async_event event;
    if (ncclSuccess != wrap_ibv_get_async_event(context, &event)) { break; }
    char *str;
    if (ncclSuccess != wrap_ibv_event_type_str(&str, event.event_type)) { break; }
    if (event.event_type != IBV_EVENT_COMM_EST)
      WARN("IB Got async event : %s", str);
    if (ncclSuccess != wrap_ibv_ack_async_event(&event)) { break; }
  }
  return NULL;
}

static void initDevices() {
  if(wrap_ibv_symbols() != ncclSuccess) { return; }
  if (ncclNIbDevs == -1) {
    pthread_mutex_lock(&ncclIbLock);
    if (ncclNIbDevs == -1) {
      // Allow user to force the INET socket family selection
      int sock_family = envSocketFamily();
      // Get an IP card for OOB transport
      char* env = getenv("NCCL_SOCKET_IFNAME");
      if (env && strlen(env) > 1) {
        // Specified by user : find or fail
        if (findInterfaces(env, ncclIbIfName, &ncclIbIfAddr, sock_family, MAX_IF_NAME_SIZE, 1) == 0) {
          WARN("NET/IB : No IP interface found (starting with %s).", env);
          return;
        }
      } else {
        // Try to automatically pick one that will work, but not loopback
        if (findInterfaces("^lo", ncclIbIfName, &ncclIbIfAddr, sock_family, MAX_IF_NAME_SIZE, 1) == 0) {
          WARN("NET/IB : No IP interface found.");
          return;
        }
      }
      INFO("NET/IB : Using interface %s for sideband communication", ncclIbIfName);

      // Detect IB cards
      int nIbDevs;
      ncclNIbDevs = 0;
      struct ibv_device** devices;
      
      // Check if user defined which IB device:port to use
      char* userIbEnv = getenv("NCCL_IB_HCA");
      struct netIf userIfs[MAX_IB_DEVS];
      bool searchNot = userIbEnv && userIbEnv[0] == '^';
      int nUserIfs = parseStringList(userIbEnv, userIfs, MAX_IB_DEVS);

      if (ncclSuccess != wrap_ibv_get_device_list(&devices, &nIbDevs)) return;

      for (int d=0; d<nIbDevs; d++) {
        struct ibv_context * context; 
        if (ncclSuccess != wrap_ibv_open_device(&context, devices[d])) {
            WARN("NET/IB : Unable to open device %s", devices[d]->name);
            continue;
        }
        int found = 0;
        if (context) {
          struct ibv_device_attr devAttr;
          if (ncclSuccess != wrap_ibv_query_device(context, &devAttr)) {
            WARN("NET/IB : Unable to query device %s", devices[d]->name);
            continue;
          }
          for (int port = 1; port <= devAttr.phys_port_cnt; port++) {
            struct ibv_port_attr portAttr;
            if (ncclSuccess != wrap_ibv_query_port(context, port, &portAttr)) {
              WARN("NET/IB : Unable to query port %d", port);
              continue;
            }
            if (portAttr.state != IBV_PORT_ACTIVE) continue;

            // check against user specified HCAs/ports
            if (! (matchIfList(devices[d]->name, port, userIfs, nUserIfs) ^ searchNot)) {
              continue;
            }
            INFO("Using %s port %d", devices[d]->name, port);
            ncclIbDevs[ncclNIbDevs].device = d;
            ncclIbDevs[ncclNIbDevs].port = port;
            ncclIbDevs[ncclNIbDevs].context = context;
            strncpy(ncclIbDevs[ncclNIbDevs].devPath, devices[d]->ibdev_path, MAXPATHSIZE);
            strncpy(ncclIbDevs[ncclNIbDevs].devName, devices[d]->name, MAXNAMESIZE);
            ncclNIbDevs++;
            found++;
            pthread_create(&ncclIbAsyncThread, NULL, ncclIbAsyncThreadMain, context);
          } 

          if (found == 0) { if (ncclSuccess != wrap_ibv_close_device(context)) { return; } }
        }
      }
      if (ncclSuccess != wrap_ibv_free_device_list(devices)) { return; };
    }

    char* env = getenv("NCCL_IB_TIMEOUT");
    if (env && strlen(env) > 1) ncclIbTimeout = atoi(env);

    pthread_mutex_unlock(&ncclIbLock);
  }
}

int ncclIbDevices(int* ndev, int** scores) {
  initDevices();
  *ndev = ncclNIbDevs;
  int cudaDev;
  cudaGetDevice(&cudaDev);
  char* cudaPath;
  ncclResult_t err1 = getCudaPath(cudaDev, &cudaPath);
  int* sc = (int*)malloc(ncclNIbDevs*sizeof(int));
  char line[1024];
  sprintf(line, "CUDA Dev %d, IB Ports : ", cudaDev);
  for (int d=0; d<ncclNIbDevs; d++) {
    char* mlxPath;
    ncclResult_t err2 = getMlxPath(ncclIbDevs[d].devPath, &mlxPath);
    int distance = (err1 != ncclSuccess || err2 != ncclSuccess || mlxPath == NULL || cudaPath == NULL) ? PATH_SOC : pciDistance(mlxPath, cudaPath);
    sprintf(line+strlen(line), "%s/%d(%s) ", ncclIbDevs[d].devName, ncclIbDevs[d].port, pathDists[distance]);
    sc[d] = 1+PATH_SOC-distance;
    if (err2 == ncclSuccess) free(mlxPath);
  }
  INFO("%s", line);
  if (err1 == ncclSuccess) free(cudaPath);
  *scores = sc;
  return ncclSuccess;
}

int ncclIbGdrSupport() {
  return (access("/sys/kernel/mm/memory_peers/nv_mem/version", F_OK) == -1) ? 0 : 1;
}

int ncclIbPtrSupport(int dev, int* supportedTypes) {
  initDevices();
  *supportedTypes = NCCL_PTR_HOST;
  int ibGdrEnabled = 0;
  char* str = getenv("NCCL_IB_CUDA_SUPPORT");
  if (str && strlen(str) > 0) {
    ibGdrEnabled = atoi(str);
  } else { // auto detect
    int cudaDev;
    cudaGetDevice(&cudaDev);
    char* cudaPath;
    getCudaPath(cudaDev, &cudaPath);
    char* mlxPath;
    getMlxPath(ncclIbDevs[dev].devPath, &mlxPath);
    int distance = (mlxPath == NULL || cudaPath == NULL) ? PATH_SOC : pciDistance(mlxPath, cudaPath);
    free(mlxPath); free(cudaPath);
    if (distance <= PATH_PXB) ibGdrEnabled = 1;
  }
  int ibGdrSupport = ncclIbGdrSupport();
  if (ibGdrEnabled == 1) {
    if (ibGdrSupport == 0)
      WARN("No module present for GPU Direct RDMA.");
    else
      *supportedTypes |= NCCL_PTR_CUDA;
  }
  return 0;
}

static ncclResult_t GetSocketAddr(union socketAddress* addr) {
  if (ncclNIbDevs == -1) initDevices();
  memcpy(addr, &ncclIbIfAddr, sizeof(*addr));
  return ncclSuccess;
}

#define MAX_REQUESTS 64 /*XXX:Can support 62 outstanding requests*/

struct ncclIbQpInfo {
  int lid;
  uint8_t ib_port;
  int qpn;
  uint32_t fifoRkey;
  uint64_t fifoAddr;
};

struct ncclIbHandle {
  union socketAddress connectAddr;
  struct ncclIbQpInfo qpInfo;
};

struct ncclIbMr {
  struct ibv_mr* mr;
  int refcnt;
};

struct ncclIbVerbs {
  struct ibv_pd* pd;
  struct ibv_comp_channel* cc;
  struct ibv_cq* cq;
  int numRequests;
  struct ncclIbMr mrPool[MAX_REQUESTS];
  int mrRotation;
};

struct ncclIbRequest {
  int used;
  int type;
  struct ncclIbVerbs* verbs;
  struct ncclIbMr * ibMr;
  void * flushDataPtr;
  int done;
  int size;
  void* comm;
};

struct ncclIbListenComm {
  int dev;
  int fd;
};

struct ncclIbReqs {
  int nreqs;
  struct ncclIbRequest* requests;
};

struct ncclIbSendFifo {
  uint64_t addr;
  uint32_t rkey;
  int ready;
};

struct ncclIbSendComm {
  int fd;
  int ready;
  struct ncclIbVerbs verbs;
  struct ibv_qp* qp;
  struct ncclIbReqs reqs;
  struct ncclIbSendFifo fifo[MAX_REQUESTS];
  struct ibv_mr* fifoMr;
  int fifoHead;
};

struct ncclIbGpuFlush {
  int enabled;
  int hostMem;
  struct ibv_mr* hostMr;
  struct ibv_sge sge;
  struct ibv_qp* qp;
};

struct ncclIbRemFifo {
  uint32_t rkey;
  uint64_t addr;
  int tail;
  struct ncclIbSendFifo elem;
  struct ibv_mr* mr;
  struct ibv_sge sge;
};

struct ncclIbRecvComm {
  int fd;
  int ready;
  struct ncclIbVerbs verbs;
  struct ibv_qp* qp;
  struct ncclIbReqs reqs;
  struct ncclIbRemFifo remFifo;
  struct ncclIbGpuFlush gpuFlush;
};

#define NULLCHECK(cmd) \
  if ((cmd) == NULL) { \
    WARN("IBV call return NULL\n"); \
  }

ncclResult_t ncclIbInitVerbs(ibv_context* ctx, struct ncclIbVerbs* verbs) {
  NCCLCHECK(wrap_ibv_alloc_pd(&verbs->pd, ctx));
  NCCLCHECK(wrap_ibv_create_comp_channel(&verbs->cc, ctx));
  NCCLCHECK(wrap_ibv_create_cq(&verbs->cq, ctx, MAX_REQUESTS, NULL, verbs->cc, 0));
  return ncclSuccess;
}

ncclResult_t ncclIbDestroyVerbs(struct ncclIbVerbs* verbs) {
  NCCLCHECK(wrap_ibv_destroy_cq(verbs->cq));
  NCCLCHECK(wrap_ibv_destroy_comp_channel(verbs->cc));
  NCCLCHECK(wrap_ibv_dealloc_pd(verbs->pd));
  return ncclSuccess;
}

ncclResult_t ncclIbCreateQp(uint8_t ib_port, struct ncclIbVerbs* verbs, int access_flags, struct ibv_qp** qp) {
  struct ibv_qp_init_attr qpInitAttr;
  memset(&qpInitAttr, 0, sizeof(struct ibv_qp_init_attr));
  qpInitAttr.send_cq = verbs->cq;
  qpInitAttr.recv_cq = verbs->cq;
  qpInitAttr.qp_type = IBV_QPT_RC;
  qpInitAttr.cap.max_send_wr = MAX_REQUESTS;
  qpInitAttr.cap.max_recv_wr = MAX_REQUESTS;
  qpInitAttr.cap.max_send_sge = 1;
  qpInitAttr.cap.max_recv_sge = 1;
  qpInitAttr.cap.max_inline_data = 0;
  NCCLCHECK(wrap_ibv_create_qp(qp, verbs->pd, &qpInitAttr));
  struct ibv_qp_attr qpAttr;
  memset(&qpAttr, 0, sizeof(struct ibv_qp_attr));
  qpAttr.qp_state = IBV_QPS_INIT;
  qpAttr.pkey_index = 0;
  qpAttr.port_num = ib_port;
  qpAttr.qp_access_flags = access_flags; //IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_LOCAL_WRITE;
  NCCLCHECK(wrap_ibv_modify_qp(*qp, &qpAttr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS));
  return ncclSuccess;
}

ncclResult_t ncclIbRtrQp(ibv_qp* qp, int qpn, int lid, uint8_t ib_port) {
  struct ibv_qp_attr qpAttr;
  memset(&qpAttr, 0, sizeof(struct ibv_qp_attr));
  qpAttr.qp_state = IBV_QPS_RTR;
  qpAttr.path_mtu = IBV_MTU_2048;
  qpAttr.dest_qp_num = qpn;
  qpAttr.rq_psn = 0;
  qpAttr.max_dest_rd_atomic = 1;
  //qpAttr.min_rnr_timer = 12;
  qpAttr.min_rnr_timer = 1;
  qpAttr.ah_attr.is_global = 0;
  qpAttr.ah_attr.dlid = lid;
  qpAttr.ah_attr.sl = 1;
  qpAttr.ah_attr.src_path_bits = 0;
  qpAttr.ah_attr.port_num = ib_port;
  NCCLCHECK(wrap_ibv_modify_qp(qp, &qpAttr, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER));
  return ncclSuccess;
}

ncclResult_t ncclIbRtsQp(ibv_qp* qp) {
  struct ibv_qp_attr qpAttr;
  memset(&qpAttr, 0, sizeof(struct ibv_qp_attr));
  qpAttr.qp_state = IBV_QPS_RTS;
  qpAttr.timeout = ncclIbTimeout;
  qpAttr.retry_cnt = 7;
  //qpAttr.rnr_retry = 7;
  qpAttr.rnr_retry = 1;
  qpAttr.sq_psn = 0;
  qpAttr.max_rd_atomic = 1;
  NCCLCHECK(wrap_ibv_modify_qp(qp, &qpAttr, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC));
  return ncclSuccess;
}


int ncclIbListen(int dev, void* opaqueHandle, void** listenComm) {
  struct ncclIbListenComm* comm = (struct ncclIbListenComm*)malloc(sizeof(struct ncclIbListenComm));
  struct ncclIbHandle* handle = (struct ncclIbHandle*) opaqueHandle;
  static_assert(sizeof(struct ncclIbHandle) < NCCL_NET_HANDLE_MAXSIZE, "ncclIbHandle size too large");
  comm->dev = dev;
  NCCLCHECK(GetSocketAddr(&(handle->connectAddr)));
  NCCLCHECK(createListenSocket(&comm->fd, &handle->connectAddr));
  *listenComm = comm;
  return 0;
}

int ncclIbConnect(int dev, void* opaqueHandle, void** sendComm) {
  struct ncclIbSendComm* comm = (struct ncclIbSendComm*)malloc(sizeof(struct ncclIbSendComm));
  memset(comm, 0, sizeof(struct ncclIbSendComm));
  struct ncclIbHandle* handle = (struct ncclIbHandle*) opaqueHandle;
  NCCLCHECK(connectAddress(&handle->connectAddr, &ncclIbIfAddr, &comm->fd));
  *sendComm = comm;
  
  // IB Setup
  initDevices(); /*XXX: Need this for ncclNet unit test that bypasses nccl initialization*/
  ibv_context* ctx = ncclIbDevs[dev].context;
  NCCLCHECK(ncclIbInitVerbs(ctx, &comm->verbs));
  uint8_t ib_port = ncclIbDevs[dev].port;
  NCCLCHECK(ncclIbCreateQp(ib_port, &comm->verbs, IBV_ACCESS_REMOTE_WRITE, &comm->qp));

  // Send my QP Info to receiver through the socket. Hope this won't block.
  struct ibv_port_attr portAttr;
  NCCLCHECK(wrap_ibv_query_port(ctx, ib_port, &portAttr));
  struct ncclIbQpInfo qpInfo;
  qpInfo.lid = portAttr.lid;
  qpInfo.ib_port = ib_port;
  qpInfo.qpn = comm->qp->qp_num;

  // Prepare my fifo
  NCCLCHECK(wrap_ibv_reg_mr(&comm->fifoMr, comm->verbs.pd, comm->fifo, sizeof(struct ncclIbSendFifo)*MAX_REQUESTS, IBV_ACCESS_LOCAL_WRITE|IBV_ACCESS_REMOTE_WRITE|IBV_ACCESS_REMOTE_READ));
  qpInfo.fifoRkey = comm->fifoMr->rkey;
  qpInfo.fifoAddr = (uint64_t)comm->fifo;
   
  NCCLCHECK(socketSend(comm->fd, &qpInfo, sizeof(qpInfo)));
  return 0;
}

int ncclIbAccept(void* listenComm, void** recvComm) {
  struct ncclIbListenComm* lComm = (struct ncclIbListenComm*)listenComm;
  struct ncclIbRecvComm* rComm = (struct ncclIbRecvComm*)malloc(sizeof(struct ncclIbRecvComm));
  memset(rComm, 0, sizeof(struct ncclIbRecvComm));
  
  struct sockaddr_in sockaddr;
  socklen_t socklen = sizeof(struct sockaddr_in);
  SYSCHECKVAL(accept(lComm->fd, (struct sockaddr*)&sockaddr, &socklen), "accept", rComm->fd);
  struct ncclIbQpInfo remQpInfo;
  NCCLCHECK(socketReceive(rComm->fd, &remQpInfo, sizeof(remQpInfo)));

  // IB setup
  ibv_context* ctx = ncclIbDevs[lComm->dev].context;
  NCCLCHECK(ncclIbInitVerbs(ctx, &rComm->verbs));
  uint8_t ib_port = ncclIbDevs[lComm->dev].port;
  NCCLCHECK(ncclIbCreateQp(ib_port, &rComm->verbs, IBV_ACCESS_REMOTE_WRITE, &rComm->qp));

  struct ibv_qp* qp = rComm->qp;
  NCCLCHECK(ncclIbRtrQp(qp, remQpInfo.qpn, remQpInfo.lid, remQpInfo.ib_port));
  NCCLCHECK(ncclIbRtsQp(qp));

  // Retain remote fifo info and prepare my RDMA ops
  rComm->remFifo.rkey = remQpInfo.fifoRkey;
  rComm->remFifo.addr = remQpInfo.fifoAddr;
  NCCLCHECK(wrap_ibv_reg_mr(&rComm->remFifo.mr, rComm->verbs.pd, &rComm->remFifo.elem, sizeof(struct ncclIbSendFifo), IBV_ACCESS_REMOTE_WRITE|IBV_ACCESS_LOCAL_WRITE|IBV_ACCESS_REMOTE_READ));
  rComm->remFifo.sge.addr = (uint64_t)&rComm->remFifo.elem;
  rComm->remFifo.sge.length = sizeof(struct ncclIbSendFifo);
  rComm->remFifo.sge.lkey = rComm->remFifo.mr->lkey;

  // Allocate Flush dummy buffer for GPU Direct RDMA
  rComm->gpuFlush.enabled = 1;
  char *str = getenv("NCCL_GDR_FLUSH_DISABLE");
  if (str && strlen(str) > 0 && atoi(str) > 0) {
    rComm->gpuFlush.enabled = 0;
    INFO("GDR Flush is disabled");
  }
  if (ncclIbGdrSupport() && rComm->gpuFlush.enabled) {
    NCCLCHECK(wrap_ibv_reg_mr(&rComm->gpuFlush.hostMr, rComm->verbs.pd, &rComm->gpuFlush.hostMem, sizeof(int), IBV_ACCESS_LOCAL_WRITE));
    rComm->gpuFlush.sge.addr = (uint64_t)&rComm->gpuFlush.hostMem;
    rComm->gpuFlush.sge.length = sizeof(int);
    rComm->gpuFlush.sge.lkey = rComm->gpuFlush.hostMr->lkey;
    uint8_t port = ncclIbDevs[lComm->dev].port;
    NCCLCHECK(ncclIbCreateQp(port, &rComm->verbs, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ, &rComm->gpuFlush.qp));
    struct ibv_port_attr portAttr;
    NCCLCHECK(wrap_ibv_query_port(ctx, port, &portAttr));
    NCCLCHECK(ncclIbRtrQp(rComm->gpuFlush.qp, rComm->gpuFlush.qp->qp_num, portAttr.lid, port));
    NCCLCHECK(ncclIbRtsQp(rComm->gpuFlush.qp));
  }

  // Fill Handle
  struct ibv_port_attr portAttr;
  NCCLCHECK(wrap_ibv_query_port(ctx, ib_port, &portAttr));
  struct ncclIbQpInfo qpInfo;
  qpInfo.lid = portAttr.lid;
  qpInfo.ib_port = ib_port;
  qpInfo.qpn = qp->qp_num;

  NCCLCHECK(socketSend(rComm->fd, &qpInfo, sizeof(qpInfo)));
  *recvComm = rComm;
  return 0;
}

struct ncclIbRequest* ncclIbGetRequest(struct ncclIbReqs* reqs, struct ncclIbVerbs* verbs) {
  for (int i=0; i<reqs->nreqs; i++) {
    struct ncclIbRequest* req = reqs->requests+i;
    if (req->used == 0) {
      req->used = 1;
      req->ibMr = NULL;
      req->done = 0;
      req->size = 0;
      req->verbs = verbs;
      return req;
    }
  }
  // No free request found, grow the pool
  int newNumRequests = reqs->nreqs + 32;
  reqs->requests = (struct ncclIbRequest*)realloc(reqs->requests, newNumRequests*sizeof(struct ncclIbRequest));
  for (int i=reqs->nreqs; i<newNumRequests; i++)
    reqs->requests[i].used = 0;
  reqs->nreqs = newNumRequests;
  return ncclIbGetRequest(reqs, verbs);
}

ncclResult_t ncclSendCheck(struct ncclIbSendComm* comm) {
  if (comm->ready == 0) {
    struct ncclIbQpInfo remQpInfo;
    struct ibv_qp* qp = comm->qp;
    NCCLCHECK(socketReceive(comm->fd, &remQpInfo, sizeof(remQpInfo)));
    NCCLCHECK(ncclIbRtrQp(qp, remQpInfo.qpn, remQpInfo.lid, remQpInfo.ib_port));
    NCCLCHECK(ncclIbRtsQp(qp));
    int go = 1;
    NCCLCHECK(socketSend(comm->fd, &go, sizeof(go)));
    comm->ready = 1;
  }
  return ncclSuccess;
}

ncclResult_t ncclRecvCheck(struct ncclIbRecvComm* comm) {
  if (comm->ready == 0) {
    int go;
    NCCLCHECK(socketReceive(comm->fd, &go, sizeof(go)));
    comm->ready = 1;
  }
  return ncclSuccess;
}

int ncclIbTest(void* request, int* done, int* size);

#define REG_ALIGN (4096)

// Cache previous MRs to avoid registering/unregistering for each Isend/Irecv
ncclResult_t ncclIbGetMr(struct ncclIbVerbs* verbs, void* data, int size, struct ncclIbMr** mrRet) {
  uint64_t addr = (uint64_t)data;
  int elem = -1;

  // Look for an already existing MR
  for (int i=0; i<MAX_REQUESTS;i++) {
    if (verbs->mrPool[i].mr == NULL) continue;
    uint64_t regAddr = (uint64_t)verbs->mrPool[i].mr->addr;
    uint64_t regSize = (uint64_t)verbs->mrPool[i].mr->length;
    if (regAddr <= addr && addr < regAddr + regSize) {
      if (addr+size <= regAddr + regSize) {
        *mrRet = verbs->mrPool+i;
        verbs->mrPool[i].refcnt++;
        return ncclSuccess;
      } else { // Size too small, delete the area (and recreate it, larger)
        elem = i;
        break;
      }
    }
  }

  // Find an unused element
  if (elem == -1) {
    elem = (verbs->mrRotation++)%MAX_REQUESTS;
    for (int i=0; i<MAX_REQUESTS;i++) {
      if (verbs->mrPool[elem].refcnt > 0) elem++; else break;
    }
    if (verbs->mrPool[elem].refcnt > 0) {
      WARN("IB memory register : no MR available");
      return ncclInternalError;
    }
  }

  // Deregister / register
  uint64_t regAddr = addr & (~(REG_ALIGN-1));
  uint64_t regSize = addr+size - regAddr;
  regSize = ((regSize + REG_ALIGN-1) / REG_ALIGN ) * REG_ALIGN;
  if (verbs->mrPool[elem].mr) NCCLCHECK(wrap_ibv_dereg_mr(verbs->mrPool[elem].mr));
  NCCLCHECK(wrap_ibv_reg_mr(&verbs->mrPool[elem].mr, verbs->pd, (void*)regAddr, regSize, IBV_ACCESS_LOCAL_WRITE|IBV_ACCESS_REMOTE_WRITE|IBV_ACCESS_REMOTE_READ));
  *mrRet = verbs->mrPool+elem;
  verbs->mrPool[elem].refcnt++;
  return ncclSuccess;
}

int ncclIbIsend(void* sendComm, void* data, int size, int type, void** request) {
  struct ncclIbSendComm* comm = (struct ncclIbSendComm*)sendComm;
  NCCLCHECK(ncclSendCheck(comm));

  struct ncclIbRequest* req = ncclIbGetRequest(&comm->reqs, &comm->verbs);
  req->done = 0;
  req->size = size;
  req->verbs = &comm->verbs;
  req->type = type;

  struct ibv_send_wr wr;
  memset(&wr, 0, sizeof(wr));
  wr.wr_id = (uint64_t)req;

  struct ibv_sge sge;
  if (size == 0) {
    wr.sg_list = NULL;
    wr.num_sge = 0;
    req->ibMr = NULL;
  } else {
    NCCLCHECK(ncclIbGetMr(&comm->verbs, data, size, &req->ibMr));
    sge.addr=(uintptr_t)data; sge.length=(unsigned int)size; sge.lkey=req->ibMr->mr->lkey;
    wr.sg_list = &sge;
    wr.num_sge = 1;
  }
  wr.opcode = IBV_WR_SEND;
  wr.send_flags = IBV_SEND_SIGNALED;

  // Wait for WR to be available in the Send Queue
  while (comm->verbs.numRequests == MAX_REQUESTS) { 
     int done = 0;
     /* This request is not even posted, but that should make the CQ progress */
     NCCLCHECK((ncclResult_t)ncclIbTest(req, &done, NULL));
     if (comm->verbs.numRequests == MAX_REQUESTS) sched_yield();
  }

  // Wait for receiver to have posted the recv
  volatile struct ncclIbSendFifo* slot = comm->fifo + (comm->fifoHead%MAX_REQUESTS);
  while (slot->ready == 0) sched_yield(); /*XXX:if commented, ibv_post_send in ncclIbPostFifo should also be commented*/
#ifdef USE_RDMA_WRITE
  wr.opcode = IBV_WR_RDMA_WRITE_WITH_IMM;
  wr.wr.rdma.remote_addr = slot->addr;
  wr.wr.rdma.rkey = slot->rkey;
  wr.imm_data = size;
#endif
  slot->ready = 0;
  comm->fifoHead++;

  struct ibv_send_wr* bad_wr;
  NCCLCHECK(wrap_ibv_post_send(comm->qp, &wr, &bad_wr));
  comm->verbs.numRequests++;
  *request = req;
  return 0;
}

ncclResult_t ncclIbPostFifo(struct ncclIbRecvComm* comm, uint32_t rkey, uint64_t addr) {
  struct ibv_send_wr wr;
  memset(&wr, 0, sizeof(wr));
  struct ncclIbRequest* req = ncclIbGetRequest(&comm->reqs, &comm->verbs);
  wr.wr_id = (uint64_t)req;

  comm->remFifo.elem.addr = addr;
  comm->remFifo.elem.rkey = rkey;
  comm->remFifo.elem.ready = 1;
  wr.wr.rdma.remote_addr = comm->remFifo.addr + (comm->remFifo.tail % MAX_REQUESTS) * sizeof(struct ncclIbSendFifo);
  wr.wr.rdma.rkey = comm->remFifo.rkey;
  wr.sg_list = &comm->remFifo.sge;
  wr.num_sge = 1;
  wr.opcode = IBV_WR_RDMA_WRITE;
  wr.send_flags = IBV_SEND_SIGNALED;

  // Wait for WR to be available in the RQ
  while (comm->verbs.numRequests == MAX_REQUESTS) { 
     int done = 0;
     /* This request is not even posted, but that should make the CQ progress */
     NCCLCHECK((ncclResult_t)ncclIbTest(req, &done, NULL));
     if (comm->verbs.numRequests == MAX_REQUESTS) sched_yield();
  }

  struct ibv_send_wr* bad_wr;
  NCCLCHECK(wrap_ibv_post_send(comm->qp, &wr, &bad_wr));
  comm->verbs.numRequests++;
  comm->remFifo.tail++;
  
  while (req->done == 0) {
    int done;
    NCCLCHECK((ncclResult_t)ncclIbTest(req, &done, NULL));
  }
  
  return ncclSuccess;
}

int ncclIbIrecv(void* recvComm, void* data, int size, int type, void** request) {
  struct ncclIbRecvComm* comm = (struct ncclIbRecvComm*)recvComm;
  struct ncclIbRequest* req = ncclIbGetRequest(&comm->reqs, &comm->verbs);
  NCCLCHECK(ncclRecvCheck(comm));
  req->done = 0;
  req->size = size;
  req->verbs = &comm->verbs;
  req->type = type;
  req->comm = comm;
  req->flushDataPtr = (size > 0 && type == NCCL_PTR_CUDA) ? data : NULL;

  struct ibv_recv_wr wr;
  memset(&wr, 0, sizeof(wr));
  wr.wr_id = (uint64_t)req;

  struct ibv_sge sge;
  if (size == 0) {
    wr.sg_list = NULL;
    wr.num_sge = 0;
    req->ibMr = NULL;
  } else {
    NCCLCHECK(ncclIbGetMr(&comm->verbs, data, size, &req->ibMr));
    sge.addr=(uintptr_t)data; sge.length=(unsigned int)size; sge.lkey=req->ibMr->mr->lkey;
    wr.sg_list = &sge;
    wr.num_sge = 1;
  }

  // Wait for WR to be available in the RQ
  while (comm->verbs.numRequests == MAX_REQUESTS) { 
     int done = 0;
     /* This request is not even posted, but that should make the CQ progress */
     NCCLCHECK((ncclResult_t)ncclIbTest(req, &done, NULL));
     if (comm->verbs.numRequests == MAX_REQUESTS) sched_yield();
  }

  struct ibv_recv_wr* bad_wr;
  NCCLCHECK(wrap_ibv_post_recv(comm->qp, &wr, &bad_wr));
  comm->verbs.numRequests++;
  *request = req;

  // Post to FIFO to notify sender
  NCCLCHECK(ncclIbPostFifo(comm, req->ibMr->mr->rkey, (uint64_t)data));
  return ncclSuccess;
}

ncclResult_t ncclIbFlush(struct ncclIbRequest* req) {
  struct ncclIbRecvComm* comm = (struct ncclIbRecvComm*)req->comm;
  if (comm->gpuFlush.enabled == 0) return ncclSuccess;

  struct ibv_send_wr wr;
  memset(&wr, 0, sizeof(wr));
  wr.wr_id = (uint64_t)req;

  wr.wr.rdma.remote_addr = (uint64_t)req->flushDataPtr;
  wr.wr.rdma.rkey = req->ibMr->mr->rkey;
  wr.sg_list = &comm->gpuFlush.sge;
  wr.num_sge = 1;
  wr.opcode = IBV_WR_RDMA_READ;
  wr.send_flags = IBV_SEND_SIGNALED;

  // Wait for WR to be available in the RQ
  while (comm->verbs.numRequests == MAX_REQUESTS) { 
     int done = 0;
     /* This request is not even posted, but that should make the CQ progress */
     NCCLCHECK((ncclResult_t)ncclIbTest(req, &done, NULL));
     if (comm->verbs.numRequests == MAX_REQUESTS) sched_yield();
  }

  struct ibv_send_wr* bad_wr;
  NCCLCHECK(wrap_ibv_post_send(comm->gpuFlush.qp, &wr, &bad_wr));
  comm->verbs.numRequests++;

  while (req->done == 0) {
    int done;
    NCCLCHECK((ncclResult_t)ncclIbTest(req, &done, NULL));
  }
  
  return ncclSuccess;
}

int ncclIbTest(void* request, int* done, int* size) {
  struct ncclIbRequest *r = (struct ncclIbRequest*)request;
  for (int wrDone = 1; wrDone;) {
    struct ibv_wc wc;
    //SYSCHECKVAL(wrap_ibv_poll_cq(r->verbs->cq, 1, &wc), "ibv_poll_cq", wrDone);
    wrDone = wrap_ibv_poll_cq(r->verbs->cq, 1, &wc);
    if(wrDone < 0){ return ncclSystemError; }
    if (wrDone == 1) {
      if (wc.status != IBV_WC_SUCCESS) {
        WARN("NET/IB : Got completion with error %d, opcode %d, vendor err %d", wc.status, wc.opcode, wc.vendor_err);
        return 1;
      }
      r->verbs->numRequests--;

      struct ncclIbRequest* doneReq = (struct ncclIbRequest*)wc.wr_id;
      if (doneReq) {
        if (wc.opcode == IBV_WC_RECV) {
          doneReq->size = wc.byte_len;
          if (doneReq->flushDataPtr != NULL) NCCLCHECK(ncclIbFlush(doneReq));
#ifdef USE_RDMA_WRITE
        } else if (wc.opcode == IBV_WC_RECV_RDMA_WITH_IMM) {
          doneReq->size = wc.imm_data;
          if (doneReq->flushDataPtr != NULL) NCCLCHECK(ncclIbFlush(doneReq));
#endif
        }
	if (doneReq->ibMr != NULL) {
	  doneReq->ibMr->refcnt--;
	}
        doneReq->done = 1;
      }  
    }
  }

  *done = 0;
  if (r->done == 1) {
    *done = 1;
    if (size) *size = r->size;
    r->used = 0;
  }
  return 0;
}

int ncclIbCloseSend(void* sendComm) {
  struct ncclIbSendComm* comm = (struct ncclIbSendComm*)sendComm;
  if (comm) {
    free(comm->reqs.requests);
    close(comm->fd);
    if (comm->qp != NULL) NCCLCHECK(wrap_ibv_destroy_qp(comm->qp));
    if (comm->fifoMr != NULL) NCCLCHECK(wrap_ibv_dereg_mr(comm->fifoMr));
    for (int i=0; i<MAX_REQUESTS; i++) {
      if (comm->verbs.mrPool[i].mr != NULL) {
	if (comm->verbs.mrPool[i].refcnt != 0) WARN("IB MR #%d has non-zero refcnt", i);
	NCCLCHECK(wrap_ibv_dereg_mr(comm->verbs.mrPool[i].mr));
      }
    }
    NCCLCHECK(ncclIbDestroyVerbs(&comm->verbs));
    free(comm);
  }
  return 0;
}

int ncclIbCloseRecv(void* recvComm) {
  struct ncclIbRecvComm* comm = (struct ncclIbRecvComm*)recvComm;
  if (comm) {
    free(comm->reqs.requests);
    close(comm->fd);
    if (comm->qp != NULL) NCCLCHECK(wrap_ibv_destroy_qp(comm->qp));
    if (comm->gpuFlush.enabled) {
      if (comm->gpuFlush.qp != NULL) NCCLCHECK(wrap_ibv_destroy_qp(comm->gpuFlush.qp));
      if (comm->gpuFlush.hostMr != NULL) NCCLCHECK(wrap_ibv_dereg_mr(comm->gpuFlush.hostMr));
    }
    if (comm->remFifo.mr != NULL) NCCLCHECK(wrap_ibv_dereg_mr(comm->remFifo.mr));
    for (int i=0; i<MAX_REQUESTS; i++) {
      if (comm->verbs.mrPool[i].mr != NULL) {
        if (comm->verbs.mrPool[i].refcnt != 0) WARN("IB MR #%d has non-zero refcnt", i);
        NCCLCHECK(wrap_ibv_dereg_mr(comm->verbs.mrPool[i].mr));
      }
    }
    NCCLCHECK(ncclIbDestroyVerbs(&comm->verbs));
    free(comm);
  }
  return 0;
}

int ncclIbCloseListen(void* listenComm) {
  struct ncclIbListenComm* comm = (struct ncclIbListenComm*)listenComm;
  if (comm) {
    close(comm->fd);
    free(comm);
  }
  return 0;
}

ncclNet_t ncclNetIb = {
  "IB",
  ncclIbDevices,
  ncclIbPtrSupport,
  ncclIbListen,
  ncclIbConnect,
  ncclIbAccept,
  ncclIbIsend,
  ncclIbIrecv,
  ncclIbTest,
  ncclIbCloseSend,
  ncclIbCloseRecv,
  ncclIbCloseListen
};

bool ncclIbSupport() {
  initDevices();
  return ncclNIbDevs > 0;
}

