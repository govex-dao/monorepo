import { createBrowserRouter } from "react-router-dom";
import { Root } from "./root";
import { CreateDashboard } from "@/routes/CreateDashboard";
import { TradeDashboard } from "@/routes/TradeDashboard";
import { ProposalView } from "@/routes/ProposalView";
import { DaoView } from "@/routes/DaoView";

export const router = createBrowserRouter([
  {
    path: "/",
    element: <Root />,
    children: [
      {
        index: true,
        element: <TradeDashboard />, // This will handle /?dao={daoid}
      },
      {
        path: "create",
        element: <CreateDashboard />, // This will handle /create?dao={daoid}
      },
      {
        path: "trade/:proposalId",
        element: <ProposalView />,
      },
      {
        path: "dao/:daoId",
        element: <DaoView />,
      },
    ],
  },
]);
