/*
 * Copyright (c) 2026 ETH Zurich and University of Bologna.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Header file for Ara MultiCore Wafer-Scale Engine (WSE) Linux Kernel Driver
 * Target Hardware: PCIe Gen5 / CXL 2.0 Host Interface with MSI-X
 */

#ifndef _ARA_WSE_DRIVER_H_
#define _ARA_WSE_DRIVER_H_

#ifdef __KERNEL__
#include <linux/types.h>
#include <linux/ioctl.h>
#else
#include <stdint.h>
#include <sys/ioctl.h>
#endif

#define ARA_DRIVER_NAME     "ara_wse"
#define ARA_DEVICE_NODE     "/dev/ara_wse0"
#define ARA_PCI_VENDOR_ID   0x1E3D    /* ETH Zurich / Open-Source Silicon */
#define ARA_PCI_DEVICE_ID   0x0A2A    /* Ara WSE Many-Core Accelerator */

#define ARA_MAX_TILES       256
#define ARA_RING_BUF_SIZE   256       /* Descriptor ring buffer depth */
#define ARA_TASK_TIMEOUT_MS 5000

/* Hardware MMIO Register Offsets (BAR0) - Synchronized with ara_host_cmd_dispatcher.sv */
#define ARA_REG_DESC_0          0x0000
#define ARA_REG_DESC_1          0x0004
#define ARA_REG_DESC_2          0x0008
#define ARA_REG_DESC_3          0x000C
#define ARA_REG_DOORBELL        0x0010
#define ARA_REG_SYS_STATUS      0x0014
#define ARA_REG_GLOBAL_ABORT    0x0018    /* Write 0x18 to trigger emergency abort */
#define ARA_REG_RING_HEAD       0x0020
#define ARA_REG_RING_TAIL       0x0024    /* Safe tail update (distinct from abort) */
#define ARA_REG_COMPLETED_TASK  0x0028    /* Completed task sequence ID */
#define ARA_REG_BARRIER_STATE   0x002C
#define ARA_REG_PDN_CTRL        0x0030
#define ARA_REG_PDN_STATUS      0x0034
#define ARA_REG_IRQ_STATUS      0x0040
#define ARA_REG_IRQ_ACK         0x0044
#define ARA_REG_DESC_BASE_LO    0x0050
#define ARA_REG_DESC_BASE_HI    0x0054
#define ARA_REG_DEV_ID          0x0060
#define ARA_REG_HW_VERSION      0x0064

/* Memory Aperture Mmap Offsets */
#define ARA_MMAP_CSR_OFFSET     0x00000000ULL
#define ARA_MMAP_TCDM_OFFSET    0x10000000ULL
#define ARA_MMAP_HBM_OFFSET     0x20000000ULL

#define ARA_TCDM_REGION_SIZE    (2ULL * 1024 * 1024)       /* 2 MB per tile cluster */
#define ARA_HBM_REGION_SIZE     (16ULL * 1024 * 1024 * 1024) /* 16 GB per stack */

/* OpCodes for Task Descriptors (Synchronized with ara_multicore_cluster.sv) */
#define ARA_OP_NOP              0x0000
#define ARA_OP_GEMM             0x0001
#define ARA_OP_PIM_ATTN         0x0002
#define ARA_OP_RMSNORM          0x0002  /* Base-Die PIM RMSNorm / Attention */
#define ARA_OP_ATTENTION_PIM    0x0002
#define ARA_OP_COPY_DRAM_TCDM   0x0003
#define ARA_OP_BARRIER_SYNC     0x0004
#define ARA_OP_SWIGLU_FMA       0x0005
#define ARA_OP_TENSOR_2D        0x0006

/* Task Flags (act_fn_i[1:0] in bits [1:0]: 0=None, 1=ReLU, 2=Clamp, 3=SiLU) */
#define ARA_FLAG_ACTIVATION_NONE  0x0000
#define ARA_FLAG_ACTIVATION_RELU  0x0001
#define ARA_FLAG_ACTIVATION_CLAMP 0x0002
#define ARA_FLAG_ACTIVATION_SILU  0x0003
#define ARA_FLAG_ENABLE_IRQ       0x0004
#define ARA_FLAG_ASYNC            0x0008

/* 64-Byte Hardware Task Descriptor */
struct ara_task_desc {
    uint32_t task_id;
    uint16_t op_code;
    uint16_t cluster_mask;    /* Bitmask of targeted clusters (e.g. 0x000F for 2x2 grid) */
    uint32_t matrix_m;
    uint32_t matrix_k;
    uint32_t matrix_n;
    uint64_t src_a_addr;      /* 40-bit physical address in HBM or TCDM */
    uint64_t src_b_addr;
    uint64_t dst_c_addr;
    uint32_t flags;
    uint32_t reserved[3];     /* Pads structure to exact 64 bytes */
} __attribute__((packed, aligned(64)));

/* System Status Report */
struct ara_status_info {
    uint32_t hw_version;
    uint32_t sys_busy;
    uint32_t active_tiles;
    uint32_t pdn_safe;
    uint32_t pdn_active_domains;
    uint32_t ring_head;
    uint32_t ring_tail;
    uint32_t completed_tasks;
    uint32_t last_error;
};

/* PDN Configuration */
struct ara_pdn_config {
    uint32_t step_delay_cycles;
    uint32_t stagger_down_en;
};

/* IOCTL Command Definitions */
#define ARA_IOC_MAGIC            'A'

#define ARA_IOC_SUBMIT_TASK      _IOW(ARA_IOC_MAGIC, 1, struct ara_task_desc)
#define ARA_IOC_WAIT_TASK        _IOW(ARA_IOC_MAGIC, 2, uint32_t) /* Wait on task_id */
#define ARA_IOC_ABORT            _IO(ARA_IOC_MAGIC,  3)           /* Instant hardware abort */
#define ARA_IOC_GET_STATUS       _IOR(ARA_IOC_MAGIC, 4, struct ara_status_info)
#define ARA_IOC_CONFIG_PDN       _IOW(ARA_IOC_MAGIC, 5, struct ara_pdn_config)
#define ARA_IOC_READ_BARRIER     _IOR(ARA_IOC_MAGIC, 6, uint32_t)

#endif /* _ARA_WSE_DRIVER_H_ */
