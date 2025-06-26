/**
 * Server-side entry point for SSR (Server-Side Rendering)
 * This file is used by the server to render React components to HTML strings
 * for the initial page load, improving SEO and initial load performance.
 */

import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom';
import { QueryClient } from "@tanstack/react-query";
import { App } from './App';
import { AppProviders } from './components/AppProviders';

/**
 * Renders the app to an HTML string for server-side rendering
 * @param url - The current URL path being requested
 * @param helmetContext - Context object for react-helmet-async to collect head tags
 * @returns Object containing the rendered HTML string and helmet data for meta tags
 */
export function render(url: string, helmetContext: any = {}) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60 * 1000,
        retry: false,
      },
    },
  });

  const html = renderToString(
    <AppProviders 
      queryClient={queryClient} 
      helmetContext={helmetContext}
      includeWallet={false}
    >
      <StaticRouter location={url}>
        <App />
      </StaticRouter>
    </AppProviders>
  );

  return { html, helmet: helmetContext.helmet };
}