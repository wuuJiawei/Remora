import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'Remora Docs',
      social: {
        github: 'https://github.com/wuuJiawei/Remora',
      },
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Introduction', link: '/guides/introduction/' },
            { label: 'Installation', link: '/guides/installation/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'SSH', link: '/reference/ssh/' },
            { label: 'SFTP', link: '/reference/sftp/' },
          ],
        },
      ],
    }),
  ],
});
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'Remora Docs',
      logo: {
        src: './src/assets/logo.svg',
      },
      social: {
        github: 'https://github.com/wuuJiawei/Remora',
      },
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Introduction', link: '/guides/introduction/' },
            { label: 'Installation', link: '/guides/installation/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'SSH', link: '/reference/ssh/' },
            { label: 'SFTP', link: '/reference/sftp/' },
          ],
        },
      ],
      customCss: ['./src/styles/custom.css'],
    }),
  ],
});
