import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'
import mathjax3 from "markdown-it-mathjax3";
import footnote from "markdown-it-footnote";
import { transformerMetaWordHighlight } from '@shikijs/transformers';

// https://vitepress.dev/reference/site-config
export default defineConfig({
  base: '/VirtualPlantLab.github.io/PlantSimEngine.jl/previews/PR69/', // TODO: replace this in makedocs!
  title: 'PlantSimEngine.jl',
  description: 'Documentation for PlantSimEngine.jl',
  lastUpdated: true,
  cleanUrls: true,
  outDir: '../final_site', // This is required for MarkdownVitepress to work correctly...
  head: [['link', { rel: 'icon', href: '/DocumenterVitepress.jl/dev/favicon.ico' }]],
  
  markdown: {
    math: true,
    config(md) {
      md.use(tabsMarkdownPlugin),
      md.use(mathjax3),
      md.use(footnote)
    },
    theme: {
      light: "github-light",
      dark: "github-dark"
    },
    codeTransformers: [ transformerMetaWordHighlight(), ],

  },
  themeConfig: {
    outline: 'deep',
    // https://vitepress.dev/reference/default-theme-config
    
    search: {
      provider: 'local',
      options: {
        detailedView: true
      }
    },
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Getting Started', link: '/design' },
      { text: 'API', link: '/API' }
    ],

    sidebar: [
{ text: 'Home', link: '/index' },
{ text: 'Design', link: '/design' },
{ text: 'Model Switching', link: '/model_switching' },
{ text: 'Reducing DoF', link: '/reducing_dof' },
{ text: 'Execution', link: '/model_execution' },
{ text: 'Fitting', link: '/fitting' },
{ text: 'Extending', collapsed: false, items: [
{ text: 'Processes', link: '/./extending/implement_a_process' },
{ text: 'Models', link: '/./extending/implement_a_model' },
{ text: 'Input types', link: '/./extending/inputs' }]
 },
{ text: 'Coupling', collapsed: false, items: [
{ text: 'Users', collapsed: false, items: [
{ text: 'Simple case', link: '/./model_coupling/model_coupling_user' },
{ text: 'Multi-scale modelling', link: '/./model_coupling/multiscale' }]
 },
{ text: 'Modelers', link: '/./model_coupling/model_coupling_modeler' }]
 },
{ text: 'FAQ', collapsed: false, items: [
{ text: 'Translate a model', link: '/./FAQ/translate_a_model' }]
 },
{ text: 'API', link: '/API' }
]
,
    editLink: { pattern: "https://github.com/VirtualPlantLab/PlantSimEngine.jl/edit/main/docs/src/:path" },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/VirtualPlantLab/PlantSimEngine.jl' }
    ],
    footer: {
      message: 'Made with <a href="https://documenter.juliadocs.org/stable/" target="_blank"><strong>Documenter.jl</strong></a>, <a href="https://vitepress.dev" target="_blank"><strong>VitePress</strong></a> and <a href="https://luxdl.github.io/DocumenterVitepress.jl/stable/" target="_blank"><strong>DocumenterVitepress.jl</strong></a> <br>',
      copyright: `© Copyright ${new Date().getUTCFullYear()}.`
    }
  }
})
