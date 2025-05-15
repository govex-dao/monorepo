import { ConnectButton, useWallets } from "@mysten/dapp-kit";
import { HamburgerMenuIcon } from "@radix-ui/react-icons";
import { Box, Container, Flex, IconButton, Separator } from "@radix-ui/themes";
import { NavLink } from "react-router-dom";
import { HeaderWithGlowIcon } from "../HeaderWithGlowIcon.tsx";
import { useState, useCallback } from "react";
import { CONSTANTS } from "@/constants.ts";
import MintTestnetCoins from "../learn/MintTestnetCoins.tsx";

const menu = [
  { title: "Trade", link: "/" },
  { title: "Create", link: "/create" },
  { title: "Learn", link: "/learn"},
];

export function Header() {
  const [isOpen, setIsOpen] = useState(false);
  const wallets = useWallets()

  const handleClick = useCallback(() => {
    setIsOpen(!isOpen);
  }, [isOpen]);

  return (
    <Box className="w-screen bg-gradient-to-b from-gray-950/30 to-black/30 border-b border-gray-800 ">
      <Container className="mx-auto">
        <Flex
          position="sticky"
          px="6"
          py="3"
          justify="between"
          align="center"
          className="relative"
        >
          <Box className="flex items-center flex-1">
            <NavLink to="/">
              <HeaderWithGlowIcon />
            </NavLink>
          </Box>

          {/* Desktop Menu */}
          <Box className="hidden md:flex gap-8 items-center h-full">
            {menu.map((item) => (
              <NavLink
                key={item.link}
                to={item.link}
                className={({ isActive, isPending }) =>
                  `h-full flex items-center gap-2 text-sm font-medium transition-colors ${isPending
                    ? "text-gray-400"
                    : isActive
                      ? "text-blue-400 font-bold"
                      : "text-gray-300 hover:text-white"
                  }`
                }
              >
                {item.title}
              </NavLink>
            ))}
          </Box>

          <Flex gap="4" align="center" justify="end" className="flex-1">
            {/* Desktop Mint and Connect */}
            <Box className="hidden md:block">
              {CONSTANTS.network === "testnet" && wallets.length > 0 && (
                <MintTestnetCoins />
              )}
            </Box>
            <div className="hidden md:block">
              <ConnectButton
                connectText="Connect Wallet"
                className="!white !hover:bg-grey-100 !transition-colors"
              />
            </div>

            {/* Mobile Menu Button */}
            <Box className="md:hidden">
              <IconButton
                className="bg-gray-800 rounded-lg hover:bg-gray-700 transition-colors"
                variant="ghost"
                onClick={handleClick}
              >
                <HamburgerMenuIcon
                  width="20"
                  height="20"
                  className="text-gray-300"
                />
              </IconButton>

              {/* Dropdown overlay */}
              {isOpen && (
                <Flex gap="2" py="4" px="2" direction="column" className="absolute right-0 top-full mt-2 w-48 bg-gray-800 rounded-lg shadow-xl py-2 z-50 border border-gray-700">
                  {menu.map((item) => (
                    <NavLink
                      key={item.link}
                      to={item.link}
                      onClick={() => setIsOpen(false)}
                      className={({ isActive, isPending }) =>
                        `block px-4 py-2 -mx-2 hover:bg-gray-700 transition-colors ${isPending
                          ? "text-gray-400"
                          : isActive
                            ? "text-blue-400 font-bold"
                            : "text-gray-200"
                        }`
                      }
                    >
                      <Flex align="center" gap="2">{item.title}</Flex>
                    </NavLink>
                  ))}
                  <Separator size="4" color="gray" className="opacity-70 my-2" />

                  {/* Mint in mobile menu */}
                  {CONSTANTS.network === "testnet" && (
                    <MintTestnetCoins />
                  )}

                  <ConnectButton
                    connectText="Connect Wallet"
                    className="!bg-white w-full"
                  />
                </Flex>
              )}
            </Box>
          </Flex>
        </Flex>
      </Container>
    </Box>
  );
}

export default Header;
