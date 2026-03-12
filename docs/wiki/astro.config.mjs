import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://remora-docs.example.com',
  integrations: [
    starlight({
      title: {
        en: 'Remora',
        'zh-CN': 'Remora',
      },
      favicon: '/favicon.ico',
      defaultLocale: 'root',
      locales: {
        root: {
          label: '简体中文',
          lang: 'zh-CN',
        },
        en: {
          label: 'English',
        },
      },
      social: [
        {
          label: 'GitHub',
          icon: 'github',
          href: 'https://github.com/wuuJiawei/Remora',
        },
        {
          label: 'X (Twitter)',
          icon: 'x.com',
          href: 'https://x.com/1Javeys',
        },
      ],
      sidebar: [
        {
          label: 'Getting Started',
          translations: {
            'zh-CN': '入门指南',
          },
          items: [
            { link: '/guides/introduction/', label: 'Introduction', translations: { 'zh-CN': '简介' } },
            { link: '/guides/installation/', label: 'Installation', translations: { 'zh-CN': '安装' } },
            { link: '/guides/quick-connect/', label: 'Quick Connect', translations: { 'zh-CN': '快速连接' } },
            { link: '/guides/quick-commands/', label: 'Quick Commands', translations: { 'zh-CN': '快速命令' } },
            { link: '/guides/host-groups/', label: 'Host Groups', translations: { 'zh-CN': '主机分组' } },
            { link: '/guides/split-panes/', label: 'Split Panes', translations: { 'zh-CN': '分栏布局' } },
            { link: '/guides/local-terminal/', label: 'Local Terminal', translations: { 'zh-CN': '本地终端' } },
            { link: '/guides/import-export/', label: 'Import & Export', translations: { 'zh-CN': '导入导出' } },
            { link: '/guides/screenshots/', label: 'Screenshots', translations: { 'zh-CN': '截图' } },
            { link: '/guides/faq/', label: 'FAQ', translations: { 'zh-CN': '常见问题' } },
          ],
        },
        {
          label: 'Reference',
          translations: {
            'zh-CN': '参考',
          },
          items: [
            { link: '/reference/ssh/', label: 'SSH' },
            { link: '/reference/sftp/', label: 'SFTP' },
            { link: '/reference/terminal/', label: 'Terminal', translations: { 'zh-CN': '终端' } },
            { link: '/reference/transfer/', label: 'Transfer', translations: { 'zh-CN': '传输管理' } },
            { link: '/reference/security/', label: 'Security', translations: { 'zh-CN': '安全设置' } },
            { link: '/reference/settings/', label: 'Settings', translations: { 'zh-CN': '设置' } },
            { link: '/reference/keyboard-shortcuts/', label: 'Keyboard Shortcuts', translations: { 'zh-CN': '键盘快捷键' } },
          ],
        },
        {
          label: 'Principles',
          translations: {
            'zh-CN': '原理剖析',
          },
          items: [
            { link: '/principles/terminal-rendering/', label: 'Terminal Rendering', translations: { 'zh-CN': '终端渲染引擎' } },
            { link: '/principles/ssh-connection/', label: 'SSH Connection', translations: { 'zh-CN': 'SSH 连接复用' } },
            { link: '/principles/io-buffer/', label: 'Ring Buffer', translations: { 'zh-CN': '环形缓冲区' } },
            { link: '/principles/concurrent-transfer/', label: 'Concurrent Transfer', translations: { 'zh-CN': '并发传输控制' } },
            { link: '/principles/transfer-conflict/', label: 'Transfer Conflict', translations: { 'zh-CN': '传输冲突处理' } },
            { link: '/principles/transfer-direction/', label: 'Transfer Direction', translations: { 'zh-CN': '传输方向' } },
          ],
        },
      ],
    }),
  ],
});
