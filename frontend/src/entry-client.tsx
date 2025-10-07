/**
 * Client-side entry point for SSR hydration
 * This file is used when the app is server-side rendered.
 * It "hydrates" the server-rendered HTML by attaching React event handlers
 * and making the static HTML interactive.
 */

import ReactDOM from "react-dom/client";

import "@mysten/dapp-kit/dist/index.css";
import "@radix-ui/themes/styles.css";
import "./styles/base.css";

import { BrowserRouter } from "react-router-dom";
import { App } from "./App";
import { AppProviders } from "./components/AppProviders";

const root = document.getElementById("root");
if (!root) throw new Error("Root element not found");

// hydrateRoot is used instead of createRoot because the HTML already exists
// from server-side rendering. This attaches React to the existing DOM.
ReactDOM.hydrateRoot(
  root,
  <AppProviders>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </AppProviders>,
);