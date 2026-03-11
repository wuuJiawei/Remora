---
title: 导入与导出
description: 导入现有 SSH 配置或导出 Remora 数据。
---

Remora 支持从多种来源导入主机配置，也支持导出数据备份。

## 导入配置

### 导入格式

Remora 支持以下导入格式：

- **Remora 导出**: 从 JSON 或 CSV 文件导入
- **SSH Config**: 从 `~/.ssh/config` 导入
- **WindTerm**: 从 WindTerm user.sessions JSON 导入
- **electerm**: 从 electerm bookmark export JSON 导入
- **Xshell**: 从 Xshell `.xsh`、`.xts` 或 `.zip` 文件导入
- **PuTTY**: 从导出的 PuTTY `.reg` 文件导入

### 导入步骤

1. 打开 **Remora > 导入连接**
2. 选择导入来源
3. 选择要导入的文件
4. 选择要导入的主机
5. 点击 **导入**

## 导出数据

### 导出为 JSON

导出主机配置为 JSON 文件：

1. 打开 **Remora > 导出连接**
2. 选择导出范围（全部或指定分组）
3. 选择格式为 **JSON**
4. 选择是否包含已保存的密码
5. 选择保存位置

### 导出为 CSV

导出为 CSV 格式，便于电子表格处理。

## 数据迁移

### 迁移到新设备

1. 在旧设备上导出配置
2. 传输导出文件到新设备
3. 在新设备上导入配置

### 备份建议

- 定期备份您的配置
- 导出文件妥善保管
