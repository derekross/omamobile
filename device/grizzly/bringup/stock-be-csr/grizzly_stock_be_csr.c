// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/irq.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/string.h>
#include <linux/timekeeping.h>
#include <linux/utsname.h>

#define D1_RELEASE "6.12.81-android16-6-gf5369e7496cb-ab16467452-4k"
#define BE_CSR_ADDR 0x0f6d4004

static DEFINE_MUTEX(csr_lock);
static void __iomem *armed_csr;
static int frame_start_irq;
static bool sampled;
static u32 sample_raw;
static u64 sample_mono_ns;

static int armed_get(char *buffer, const struct kernel_param *parameter)
{
	int len;

	mutex_lock(&csr_lock);
	len = scnprintf(buffer, PAGE_SIZE, "%c\n", armed_csr ? 'Y' : 'N');
	mutex_unlock(&csr_lock);
	return len;
}

static int sample_get(char *buffer, const struct kernel_param *parameter)
{
	bool masked = false;
	int ret;

	mutex_lock(&csr_lock);
	if (!armed_csr) {
		ret = -ENODEV;
		goto unlock;
	}

	if (!sampled) {
		/* The BE runtime PM reference also keeps the parent wrapper on. */
		ret = irq_get_irqchip_state(frame_start_irq, IRQCHIP_STATE_MASKED,
					    &masked);
		if (ret || !masked) {
			pr_warn("frame-start mask check failed irq=%d status=%d masked=%u\n",
				frame_start_irq, ret, masked);
			if (!ret)
				ret = -EBUSY;
			goto unlock;
		}
		pr_info("frame-start irq=%d SGIA leaf masked\n", frame_start_irq);
		pr_info("before_read addr=0x%08x\n", BE_CSR_ADDR);
		sample_raw = readl_relaxed(armed_csr);
		sample_mono_ns = ktime_get_mono_fast_ns();
		sampled = true;
		pr_info("sampled raw=%#x mono_ns=%llu\n", sample_raw, sample_mono_ns);
	}
	ret = scnprintf(buffer, PAGE_SIZE, "raw=%#x mono_ns=%llu\n",
			sample_raw, sample_mono_ns);
unlock:
	mutex_unlock(&csr_lock);
	return ret;
}

static const struct kernel_param_ops armed_ops = {
	.get = armed_get,
};
static const struct kernel_param_ops sample_ops = {
	.get = sample_get,
};
module_param_cb(armed, &armed_ops, NULL, 0400);
module_param_cb(sample_once, &sample_ops, NULL, 0400);

static irqreturn_t reserved_frame_start(int irq, void *data)
{
	return IRQ_NONE;
}

static int grizzly_stock_be_csr_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct resource *resource;
	void __iomem *csr;
	int irq, ret;

	resource = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!resource || resource->start != BE_CSR_ADDR ||
	    resource_size(resource) != sizeof(u32) ||
	    platform_get_resource(pdev, IORESOURCE_MEM, 1))
		return dev_err_probe(dev, -EINVAL, "invalid BE CSR resource\n");
	if (!dev->pm_domain)
		return dev_err_probe(dev, -ENODEV, "missing BE power domain\n");

	irq = platform_get_irq_byname(pdev, "frame-start");
	if (irq < 0)
		return irq;

	mutex_lock(&csr_lock);
	if (armed_csr || sampled) {
		ret = -EBUSY;
		goto unlock;
	}

	pm_runtime_enable(dev);
	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0)
		goto disable_pm;

	csr = devm_ioremap_resource(dev, resource);
	if (IS_ERR(csr)) {
		ret = PTR_ERR(csr);
		goto put_pm;
	}

	/* Reserve the leaf without unmasking it or acknowledging any status. */
	ret = devm_request_irq(dev, irq, reserved_frame_start, IRQF_NO_AUTOEN,
			       dev_name(dev), dev);
	if (ret)
		goto put_pm;

	frame_start_irq = irq;
	armed_csr = csr;
	pr_info("armed irq=%d (disabled)\n", irq);
	mutex_unlock(&csr_lock);
	return 0;

put_pm:
	pm_runtime_put_sync(dev);
disable_pm:
	pm_runtime_disable(dev);
unlock:
	mutex_unlock(&csr_lock);
	return ret;
}

static void grizzly_stock_be_csr_remove(struct platform_device *pdev)
{
	mutex_lock(&csr_lock);
	armed_csr = NULL;
	devm_free_irq(&pdev->dev, frame_start_irq, &pdev->dev);
	pm_runtime_put_sync(&pdev->dev);
	pm_runtime_disable(&pdev->dev);
	mutex_unlock(&csr_lock);
}

static const struct of_device_id grizzly_stock_be_csr_match[] = {
	{ .compatible = "google,grizzly-stock-be-csr" },
	{ }
};
MODULE_DEVICE_TABLE(of, grizzly_stock_be_csr_match);

static struct platform_driver grizzly_stock_be_csr_driver = {
	.probe = grizzly_stock_be_csr_probe,
	.remove = grizzly_stock_be_csr_remove,
	.driver = {
		.name = KBUILD_MODNAME,
		.of_match_table = grizzly_stock_be_csr_match,
		.suppress_bind_attrs = true,
	},
};

static int __init grizzly_stock_be_csr_init(void)
{
	if (strcmp(init_utsname()->release, D1_RELEASE) ||
	    !of_machine_is_compatible("google,malibu-grizzly"))
		return -ENODEV;

	return platform_driver_register(&grizzly_stock_be_csr_driver);
}

static void __exit grizzly_stock_be_csr_exit(void)
{
	platform_driver_unregister(&grizzly_stock_be_csr_driver);
}

module_init(grizzly_stock_be_csr_init);
module_exit(grizzly_stock_be_csr_exit);
MODULE_DESCRIPTION("One-shot Grizzly stock D1 DPU BE output-mux sampler");
MODULE_LICENSE("GPL");
