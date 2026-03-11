import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://remora-docs.example.com',
  integrations: [
    starlight({
      title: {
        en: 'Remora Docs',
        'zh-cn': 'Remora 文档',
      },
      defaultLocale: 'en',
      locales: {
        en: {
          label: 'English',
        },
        'zh-cn': {
          label: '简体中文',
          lang: 'zh-CN',
        },
      },
      social: [
        {
          label: 'GitHub',
          icon: 'github',
          href: 'https://github.com/wuuJiawei/Remora',
        },
      ],
      sidebar: [
        {
          label: 'Getting Started',
          translations: {
            'zh-CN': '入门指南',
          },
          autogenerate: { directory: 'guides' },
        },
        {
          label: 'Reference',
          translations: {
            'zh-CN': '参考',
          },
          autogenerate: { directory: 'reference' },
        },
      ],
    }),
  ],
});
