/**
 * Client-side only entry point (non-SSR)
 * This file is used when running the app in development mode or
 * when SSR is disabled. It creates a fresh React app in the browser
 * without any server-side rendering.
 */

import ReactDOM from "react-dom/client";

import "@mysten/dapp-kit/dist/index.css";
import "@radix-ui/themes/styles.css";
import "./styles/base.css";

import { router } from "@/routes/index";
import { RouterProvider } from "react-router-dom";
import { AppProviders } from "./components/AppProviders";

const root = document.getElementById("root");
if (!root) throw new Error("Root element not found");

// createRoot is used for client-side only rendering
// This creates a new React app from scratch in the browser
ReactDOM.createRoot(root).render(
  <AppProviders>
    <RouterProvider router={router} />
  </AppProviders>,
);
