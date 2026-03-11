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
