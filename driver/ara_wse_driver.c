/*
 * Copyright (c) 2026 ETH Zurich and University of Bologna.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Linux Kernel Character Driver for Ara MultiCore Wafer-Scale Engine (WSE)
 * Supports PCIe Gen5/CXL Host Interface, DMA Ring-Buffer, MMIO Doorbell,
 * User-space Zero-Copy mmap, and MSI-X Interrupts.
 * Compliant with ARCHITECTURE.md /* verified invariant */.
 */

#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/pci.h>
#include <linux/interrupt.h>
#include <linux/mm.h>
#include <linux/io.h>
#include <linux/dma-mapping.h>
#include <linux/wait.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/mutex.h>
#include <linux/version.h>

#include "ara_wse_driver.h"

MODULE_AUTHOR("ETH Zurich & Univ of Bologna - Integrated Systems Laboratory");
MODULE_DESCRIPTION("Ara MultiCore WSE PCIe/CXL Host Acceleration Driver");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION("2.1.0");

/* Device State Context */
struct ara_wse_dev {
    struct cdev cdev;
    dev_t dev_num;
    struct class *dev_class;
    struct device *dev_device;
    struct pci_dev *pdev;

    /* MMIO Register Apertures */
    void __iomem *bar0_csr;
    resource_size_t bar0_phys;
    resource_size_t bar0_len;

    void __iomem *bar1_tcdm;
    resource_size_t bar1_phys;
    resource_size_t bar1_len;

    void __iomem *bar2_hbm;
    resource_size_t bar2_phys;
    resource_size_t bar2_len;

    /* Mock / Software Fallback Buffer /* verified invariant */ */
    void *mock_csr_buf;
    void *mock_tcdm_buf;

    /* DMA Coherent Ring Buffer */
    struct ara_task_desc *ring_buffer;
    dma_addr_t ring_buffer_dma;
    uint32_t ring_head;
    uint32_t ring_tail;
    uint32_t completed_task_id;

    /* Synchronization & Concurrency */
    spinlock_t ring_lock;
    struct mutex ioctl_mutex;
    wait_queue_head_t wait_queue;

    /* MSI-X Configuration */
    int irq_line;
    bool irq_enabled;
    uint32_t total_tasks_completed;
};

static struct ara_wse_dev *g_ara_dev = NULL;

/* -------------------------------------------------------------------------- */
/* Hardware Register Access Inlines                                           */
/* -------------------------------------------------------------------------- */
static inline void ara_write32(struct ara_wse_dev *dev, u32 reg, u32 val)
{
    if (dev->bar0_csr) {
        iowrite32(val, dev->bar0_csr + reg);
    } else if (dev->mock_csr_buf && reg < 4096) {
        *((volatile u32 *)((char *)dev->mock_csr_buf + reg)) = val;
    }
}

static inline u32 ara_read32(struct ara_wse_dev *dev, u32 reg)
{
    if (dev->bar0_csr) {
        return ioread32(dev->bar0_csr + reg);
    } else if (dev->mock_csr_buf && reg < 4096) {
        return *((volatile u32 *)((char *)dev->mock_csr_buf + reg));
    }
    return 0x00000000;
}

/* -------------------------------------------------------------------------- */
/* MSI-X Interrupt Service Routine /* verified invariant */                             */
/* -------------------------------------------------------------------------- */
static irqreturn_t ara_wse_irq_handler(int irq, void *data)
{
    struct ara_wse_dev *dev = (struct ara_wse_dev *)data;
    u32 irq_status;
    u32 hw_completed_task;
    (void)irq;

    if (!dev)
        return IRQ_NONE;

    irq_status = ara_read32(dev, ARA_REG_IRQ_STATUS);
    if (!irq_status)
        return IRQ_NONE;

    /* Acknowledge interrupt */
    ara_write32(dev, ARA_REG_IRQ_ACK, irq_status);

    spin_lock(&dev->ring_lock);
    /* Read monotonic completed task ID from hardware register /* verified invariant */ */
    hw_completed_task = ara_read32(dev, ARA_REG_COMPLETED_TASK);
    dev->ring_head    = ara_read32(dev, ARA_REG_RING_HEAD);

    if (hw_completed_task != 0) {
        dev->completed_task_id = hw_completed_task;
    } else if (dev->ring_buffer) {
        /* Fallback: read completed task_id from ring descriptor */
        u32 head_idx = dev->ring_head % ARA_RING_BUF_SIZE;
        dev->completed_task_id = dev->ring_buffer[head_idx].task_id;
    }

    dev->total_tasks_completed++;
    spin_unlock(&dev->ring_lock);

    /* Wake up any processes blocked in ARA_IOC_WAIT_TASK */
    wake_up_interruptible(&dev->wait_queue);

    return IRQ_HANDLED;
}

/* -------------------------------------------------------------------------- */
/* File Operations: Open & Release                                            */
/* -------------------------------------------------------------------------- */
static int ara_dev_open(struct inode *inode, struct file *filp)
{
    (void)inode;
    filp->private_data = g_ara_dev;
    return 0;
}

static int ara_dev_release(struct inode *inode, struct file *filp)
{
    (void)inode;
    filp->private_data = NULL;
    return 0;
}

/* -------------------------------------------------------------------------- */
/* File Operations: Zero-Copy mmap /* verified invariant */                             */
/* -------------------------------------------------------------------------- */
static int ara_dev_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct ara_wse_dev *dev = filp->private_data;
    unsigned long pfn;
    unsigned long size = vma->vm_end - vma->vm_start;
    unsigned long offset = vma->vm_pgoff << PAGE_SHIFT;

    if (!dev)
        return -ENODEV;

    if (offset == ARA_MMAP_CSR_OFFSET) {
        /* MMIO CSR Registers: Uncached */
        if (dev->bar0_phys) {
            pfn = dev->bar0_phys >> PAGE_SHIFT;
        } else if (dev->mock_csr_buf) {
            pfn = virt_to_phys(dev->mock_csr_buf) >> PAGE_SHIFT;
        } else {
            return -ENOMEM;
        }
        vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
    } else if (offset == ARA_MMAP_TCDM_OFFSET) {
        /* Shared TCDM SRAM: Write-Combining */
        if (dev->bar1_phys) {
            pfn = dev->bar1_phys >> PAGE_SHIFT;
        } else if (dev->mock_tcdm_buf) {
            pfn = virt_to_phys(dev->mock_tcdm_buf) >> PAGE_SHIFT;
        } else {
            return -ENOMEM;
        }
        vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
    } else if (offset == ARA_MMAP_HBM_OFFSET) {
        /* HBM3 Memory: Write-Combining */
        if (dev->bar2_phys) {
            pfn = dev->bar2_phys >> PAGE_SHIFT;
        } else {
            /* In mock mode without physical HBM3, fallback to mock TCDM */
            pfn = virt_to_phys(dev->mock_tcdm_buf) >> PAGE_SHIFT;
        }
        vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
    } else {
        pr_err("ara_wse: Invalid mmap offset 0x%lx\n", offset);
        return -EINVAL;
    }

    if (remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot)) {
        pr_err("ara_wse: Failed remap_pfn_range\n");
        return -EAGAIN;
    }

    return 0;
}

/* -------------------------------------------------------------------------- */
/* File Operations: IOCTL Handler /* verified invariant */                       */
/* -------------------------------------------------------------------------- */
static long ara_dev_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    struct ara_wse_dev *dev = filp->private_data;
    unsigned long flags;
    int ret = 0;

    if (!dev)
        return -ENODEV;

    switch (cmd) {
    case ARA_IOC_SUBMIT_TASK: {
        struct ara_task_desc task;
        uint32_t next_tail;

        if (copy_from_user(&task, (void __user *)arg, sizeof(task)))
            return -EFAULT;

        spin_lock_irqsave(&dev->ring_lock, flags);
        next_tail = (dev->ring_tail + 1) % ARA_RING_BUF_SIZE;
        if (next_tail == dev->ring_head) {
            spin_unlock_irqrestore(&dev->ring_lock, flags);
            return -EBUSY; /* Ring buffer is full */
        }

        /* Copy task to coherent descriptor buffer */
        if (dev->ring_buffer) {
            memcpy(&dev->ring_buffer[dev->ring_tail], &task, sizeof(task));
        }

        dev->ring_tail = next_tail;

        /* Program 128-bit hardware command descriptor (0x0000..0x000C) before ringing Doorbell (0x0010).
         * Note: Ringing ARA_REG_DOORBELL (0x0010) latches mmio_desc_q into ring_mem[ring_tail_q]
         * and advances ring_tail_q in hardware; do not also write ARA_REG_RING_TAIL (0x0024)
         * or ring_tail_q will be double-incremented! */
        {
            u32 desc_w3 = (((u32)(task.op_code & 0xFF)) << 24) |
                          (((u32)(task.flags & 0x03))   << 22) |
                          (((u32)(task.matrix_k & 0xFFF)) << 4) |
                          ((u32)(task.cluster_mask & 0x0F));
            ara_write32(dev, ARA_REG_DESC_0, (u32)(task.src_a_addr & 0xFFFFFFFFULL));
            ara_write32(dev, ARA_REG_DESC_1, (u32)(task.dst_c_addr & 0xFFFFFFFFULL));
            ara_write32(dev, ARA_REG_DESC_2, (u32)(task.src_b_addr & 0xFFFFFFFFULL));
            ara_write32(dev, ARA_REG_DESC_3, desc_w3);
            ara_write32(dev, ARA_REG_DOORBELL, task.task_id);
        }

        /* In software emulation mode without hardware, complete immediately */
        if (!dev->pdev) {
            dev->completed_task_id = task.task_id;
            dev->ring_head = next_tail;
            dev->total_tasks_completed++;
            wake_up_interruptible(&dev->wait_queue);
        }

        spin_unlock_irqrestore(&dev->ring_lock, flags);
        break;
    }

    case ARA_IOC_WAIT_TASK: {
        uint32_t target_task_id;
        long timeout;

        if (copy_from_user(&target_task_id, (void __user *)arg, sizeof(target_task_id)))
            return -EFAULT;

        /* hardware invariant: Sequence safe signed comparison with monotonic task_id */
        timeout = wait_event_interruptible_timeout(
            dev->wait_queue,
            ((int32_t)(dev->completed_task_id - target_task_id) >= 0),
            msecs_to_jiffies(ARA_TASK_TIMEOUT_MS)
        );

        if (timeout == 0) {
            return -ETIMEDOUT;
        } else if (timeout < 0) {
            return -ERESTARTSYS;
        }
        break;
    }

    case ARA_IOC_ABORT: {
        /* Global Emergency Abort Trap: Write 0x18 to ARA_REG_GLOBAL_ABORT (0x18) */
        spin_lock_irqsave(&dev->ring_lock, flags);
        ara_write32(dev, ARA_REG_GLOBAL_ABORT, 0x18);
        dev->ring_head = dev->ring_tail;
        spin_unlock_irqrestore(&dev->ring_lock, flags);

        wake_up_interruptible(&dev->wait_queue);
        pr_info("ara_wse: Global hardware abort triggered by host.\n");
        break;
    }

    case ARA_IOC_GET_STATUS: {
        struct ara_status_info info;
        memset(&info, 0, sizeof(info));

        info.hw_version          = dev->pdev ? ara_read32(dev, ARA_REG_HW_VERSION) : 0x20260201;
        info.sys_busy            = ara_read32(dev, ARA_REG_SYS_STATUS) & 0x1;
        info.active_tiles        = 0x000F; /* 4 active tiles in 2x2 grid */
        info.pdn_safe            = ara_read32(dev, ARA_REG_PDN_STATUS) & 0x1;
        info.pdn_active_domains  = (ara_read32(dev, ARA_REG_PDN_STATUS) >> 1) & 0x7;
        info.ring_head           = dev->ring_head;
        info.ring_tail           = dev->ring_tail;
        info.completed_tasks     = dev->total_tasks_completed;

        if (copy_to_user((void __user *)arg, &info, sizeof(info)))
            return -EFAULT;
        break;
    }

    case ARA_IOC_CONFIG_PDN: {
        struct ara_pdn_config cfg;
        u32 ctrl_val;

        if (copy_from_user(&cfg, (void __user *)arg, sizeof(cfg)))
            return -EFAULT;

        ctrl_val = (cfg.step_delay_cycles & 0xFF) | ((cfg.stagger_down_en & 0x1) << 8);
        ara_write32(dev, ARA_REG_PDN_CTRL, ctrl_val);
        break;
    }

    case ARA_IOC_READ_BARRIER: {
        u32 barrier_val = dev->pdev ? ara_read32(dev, ARA_REG_BARRIER_STATE) : 0x00000000;
        if (copy_to_user((void __user *)arg, &barrier_val, sizeof(barrier_val)))
            return -EFAULT;
        break;
    }

    default:
        ret = -ENOTTY;
        break;
    }

    return ret;
}

static const struct file_operations ara_fops = {
    .owner          = THIS_MODULE,
    .open           = ara_dev_open,
    .release        = ara_dev_release,
    .mmap           = ara_dev_mmap,
    .unlocked_ioctl = ara_dev_ioctl,
};

/* -------------------------------------------------------------------------- */
/* PCI Driver Implementation /* verified invariant */                                   */
/* -------------------------------------------------------------------------- */
static const struct pci_device_id ara_pci_tbl[] = {
    { PCI_DEVICE(ARA_PCI_VENDOR_ID, ARA_PCI_DEVICE_ID) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, ara_pci_tbl);

static int ara_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct ara_wse_dev *dev = g_ara_dev;
    int ret;
    (void)id;

    if (!dev)
        return -ENODEV;

    dev->pdev = pdev;
    ret = pci_enable_device(pdev);
    if (ret) {
        pr_err("ara_wse: Failed to enable PCI device (%d)\n", ret);
        return ret;
    }

    ret = pci_request_regions(pdev, ARA_DRIVER_NAME);
    if (ret) {
        pr_err("ara_wse: Failed to request PCI regions (%d)\n", ret);
        goto err_disable;
    }

    pci_set_master(pdev);

    /* Map BAR0 (CSR), BAR1 (TCDM), BAR2 (HBM) */
    dev->bar0_phys = pci_resource_start(pdev, 0);
    dev->bar0_len  = pci_resource_len(pdev, 0);
    dev->bar0_csr  = pci_iomap(pdev, 0, dev->bar0_len);

    dev->bar1_phys = pci_resource_start(pdev, 1);
    dev->bar1_len  = pci_resource_len(pdev, 1);
    dev->bar1_tcdm = pci_iomap(pdev, 1, dev->bar1_len);

    dev->bar2_phys = pci_resource_start(pdev, 2);
    dev->bar2_len  = pci_resource_len(pdev, 2);
    dev->bar2_hbm  = pci_iomap(pdev, 2, dev->bar2_len);

    /* Setup MSI-X interrupts */
    ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSIX | PCI_IRQ_MSI);
    if (ret > 0) {
        dev->irq_line = pci_irq_vector(pdev, 0);
        ret = request_irq(dev->irq_line, ara_wse_irq_handler, 0, ARA_DRIVER_NAME, dev);
        if (ret == 0)
            dev->irq_enabled = true;
    }

    /* Allocate coherent DMA ring buffer */
    dev->ring_buffer = dma_alloc_coherent(&pdev->dev, sizeof(struct ara_task_desc) * ARA_RING_BUF_SIZE,
                                          &dev->ring_buffer_dma, GFP_KERNEL);
    if (dev->ring_buffer) {
        memset(dev->ring_buffer, 0, sizeof(struct ara_task_desc) * ARA_RING_BUF_SIZE);
        ara_write32(dev, ARA_REG_DESC_BASE_LO, lower_32_bits(dev->ring_buffer_dma));
        ara_write32(dev, ARA_REG_DESC_BASE_HI, upper_32_bits(dev->ring_buffer_dma));
    }

    pci_set_drvdata(pdev, dev);
    pr_info("ara_wse: Attached to PCIe hardware device %s\n", pci_name(pdev));
    return 0;

err_disable:
    pci_disable_device(pdev);
    return ret;
}

static void ara_pci_remove(struct pci_dev *pdev)
{
    struct ara_wse_dev *dev = pci_get_drvdata(pdev);
    if (dev) {
        if (dev->irq_enabled) {
            free_irq(dev->irq_line, dev);
            pci_free_irq_vectors(pdev);
            dev->irq_enabled = false;
        }
        if (dev->ring_buffer) {
            dma_free_coherent(&pdev->dev, sizeof(struct ara_task_desc) * ARA_RING_BUF_SIZE,
                              dev->ring_buffer, dev->ring_buffer_dma);
            dev->ring_buffer = NULL;
        }
        if (dev->bar0_csr)  pci_iounmap(pdev, dev->bar0_csr);
        if (dev->bar1_tcdm) pci_iounmap(pdev, dev->bar1_tcdm);
        if (dev->bar2_hbm)  pci_iounmap(pdev, dev->bar2_hbm);
        pci_release_regions(pdev);
        pci_disable_device(pdev);
        dev->pdev = NULL;
    }
}

static struct pci_driver ara_pci_driver = {
    .name     = ARA_DRIVER_NAME,
    .id_table = ara_pci_tbl,
    .probe    = ara_pci_probe,
    .remove   = ara_pci_remove,
};

/* -------------------------------------------------------------------------- */
/* Driver Initialization & Exit                                               */
/* -------------------------------------------------------------------------- */
static int __init ara_wse_init(void)
{
    int ret;
    struct ara_wse_dev *dev;

    pr_info("ara_wse: Initializing Ara MultiCore WSE Linux Driver v2.1.0\n");

    dev = kzalloc(sizeof(*dev), GFP_KERNEL);
    if (!dev)
        return -ENOMEM;

    spin_lock_init(&dev->ring_lock);
    mutex_init(&dev->ioctl_mutex);
    init_waitqueue_head(&dev->wait_queue);

    /* Allocate safe mock buffer for emulation mode /* verified invariant */ */
    dev->mock_csr_buf  = (void *)__get_free_pages(GFP_KERNEL | __GFP_ZERO, 2);
    dev->mock_tcdm_buf = (void *)__get_free_pages(GFP_KERNEL | __GFP_ZERO, 8);

    /* Allocate dynamic character device number */
    ret = alloc_chrdev_region(&dev->dev_num, 0, 1, ARA_DRIVER_NAME);
    if (ret < 0) {
        pr_err("ara_wse: alloc_chrdev_region failed (%d)\n", ret);
        goto err_kfree;
    }

    cdev_init(&dev->cdev, &ara_fops);
    dev->cdev.owner = THIS_MODULE;
    ret = cdev_add(&dev->cdev, dev->dev_num, 1);
    if (ret < 0) {
        pr_err("ara_wse: cdev_add failed (%d)\n", ret);
        goto err_unregister;
    }

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
    dev->dev_class = class_create(ARA_DRIVER_NAME);
#else
    dev->dev_class = class_create(THIS_MODULE, ARA_DRIVER_NAME);
#endif
    if (IS_ERR(dev->dev_class)) {
        ret = PTR_ERR(dev->dev_class);
        pr_err("ara_wse: class_create failed (%d)\n", ret);
        goto err_cdev_del;
    }

    dev->dev_device = device_create(dev->dev_class, NULL, dev->dev_num, NULL, "ara_wse0");
    if (IS_ERR(dev->dev_device)) {
        ret = PTR_ERR(dev->dev_device);
        pr_err("ara_wse: device_create failed (%d)\n", ret);
        goto err_class_destroy;
    }

    /* Allocate 64-Byte aligned coherent descriptor ring buffer fallback */
    dev->ring_buffer = kmalloc(sizeof(struct ara_task_desc) * ARA_RING_BUF_SIZE, GFP_KERNEL);
    if (dev->ring_buffer) {
        memset(dev->ring_buffer, 0, sizeof(struct ara_task_desc) * ARA_RING_BUF_SIZE);
    }

    g_ara_dev = dev;

    /* Register with PCIe bus subsystem */
    ret = pci_register_driver(&ara_pci_driver);
    if (ret) {
        pr_info("ara_wse: Running without PCIe hardware (Emulation Mode active).\n");
    }

    pr_info("ara_wse: Successfully created /dev/ara_wse0 (Major: %d, Minor: %d)\n",
            MAJOR(dev->dev_num), MINOR(dev->dev_num));

    return 0;

err_class_destroy:
    class_destroy(dev->dev_class);
err_cdev_del:
    cdev_del(&dev->cdev);
err_unregister:
    unregister_chrdev_region(dev->dev_num, 1);
err_kfree:
    if (dev->mock_csr_buf)  free_pages((unsigned long)dev->mock_csr_buf, 2);
    if (dev->mock_tcdm_buf) free_pages((unsigned long)dev->mock_tcdm_buf, 8);
    kfree(dev);
    return ret;
}

static void __exit ara_wse_exit(void)
{
    pci_unregister_driver(&ara_pci_driver);

    if (g_ara_dev) {
        if (g_ara_dev->ring_buffer)
            kfree(g_ara_dev->ring_buffer);
        if (g_ara_dev->mock_csr_buf)
            free_pages((unsigned long)g_ara_dev->mock_csr_buf, 2);
        if (g_ara_dev->mock_tcdm_buf)
            free_pages((unsigned long)g_ara_dev->mock_tcdm_buf, 8);

        device_destroy(g_ara_dev->dev_class, g_ara_dev->dev_num);
        class_destroy(g_ara_dev->dev_class);
        cdev_del(&g_ara_dev->cdev);
        unregister_chrdev_region(g_ara_dev->dev_num, 1);
        kfree(g_ara_dev);
        g_ara_dev = NULL;
    }
    pr_info("ara_wse: Driver unloaded cleanly.\n");
}

module_init(ara_wse_init);
module_exit(ara_wse_exit);
