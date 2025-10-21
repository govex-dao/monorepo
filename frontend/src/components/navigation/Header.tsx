import { ConnectButton, useWallets } from "@mysten/dapp-kit";
import { HamburgerMenuIcon, GearIcon } from "@radix-ui/react-icons";
import { Box, Container, Flex, IconButton, Separator } from "@radix-ui/themes";
import { NavLink, useLocation } from "react-router-dom";
import { HeaderWithGlowIcon } from "../HeaderWithGlowIcon.tsx";
import { useState, useCallback, useRef, useEffect } from "react";
import { CONSTANTS } from "@/constants.ts";
import MintTestnetCoins from "../learn/MintTestnetCoins.tsx";

const menu = [
  { title: "Trade", link: "/" },
  { title: "Create", link: "/create" },
];

export function Header() {
  const [isOpen, setIsOpen] = useState(false);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const location = useLocation();
  const wallets = useWallets();
  const dropdownRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const settingsDropdownRef = useRef<HTMLDivElement>(null);
  const settingsButtonRef = useRef<HTMLButtonElement>(null);

  const isCreatePage = location.pathname === "/create";

  const handleClick = useCallback(() => {
    setIsOpen(!isOpen);
  }, [isOpen]);

  const handleSettingsClick = useCallback(() => {
    setIsSettingsOpen(!isSettingsOpen);
  }, [isSettingsOpen]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        buttonRef.current &&
        !dropdownRef.current.contains(event.target as Node) &&
        !buttonRef.current.contains(event.target as Node)
      ) {
        setIsOpen(false);
      }
      if (
        settingsDropdownRef.current &&
        settingsButtonRef.current &&
        !settingsDropdownRef.current.contains(event.target as Node) &&
        !settingsButtonRef.current.contains(event.target as Node)
      ) {
        setIsSettingsOpen(false);
      }
    };

    if (isOpen || isSettingsOpen) {
      document.addEventListener("mousedown", handleClickOutside);
      return () => {
        document.removeEventListener("mousedown", handleClickOutside);
      };
    }
  }, [isOpen, isSettingsOpen]);

  return (
    <Box className="w-screen bg-gradient-to-b from-gray-950/30 to-black/30 border-b border-gray-800">
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
          <Box className="hidden lg:flex gap-8 items-center h-full">
            {menu.map((item) => (
              <NavLink
                key={item.link}
                to={item.link}
                className={({ isActive, isPending }) =>
                  `h-full flex items-center gap-2 text-sm font-medium transition-colors ${
                    isPending
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
            {/* Desktop Mint - Only on Create page when on testnet */}
            {isCreatePage && CONSTANTS.network === "testnet" && wallets.length > 0 && (
              <Box className="hidden lg:block">
                <MintTestnetCoins />
              </Box>
            )}

            {/* Settings/Gear Icon - Desktop */}
            <Box className="hidden lg:block relative">
              <IconButton
                ref={settingsButtonRef}
                className="bg-gray-800 rounded-lg hover:bg-gray-700 transition-colors"
                variant="ghost"
                onClick={handleSettingsClick}
              >
                <GearIcon
                  width="18"
                  height="18"
                  className="text-gray-300"
                />
              </IconButton>

              {/* Settings Dropdown */}
              {isSettingsOpen && (
                <Flex
                  ref={settingsDropdownRef}
                  gap="2"
                  py="2"
                  px="2"
                  direction="column"
                  className="absolute right-0 top-full mt-2 w-48 bg-gray-800 rounded-lg shadow-xl py-2 z-50 border border-gray-700"
                >
                  <a
                    href="https://docs.govex.ai/"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="block px-4 py-2 -mx-2 hover:bg-gray-700 transition-colors text-gray-200 rounded"
                    onClick={() => setIsSettingsOpen(false)}
                  >
                    <Flex align="center" gap="2">
                      Documentation
                    </Flex>
                  </a>
                </Flex>
              )}
            </Box>

            <div className="hidden lg:block">
              <ConnectButton
                connectText="Connect Wallet"
                className="!white !hover:bg-grey-100 !transition-colors"
              />
            </div>

            {/* Mobile Menu Button */}
            <Box className="lg:hidden">
              <IconButton
                ref={buttonRef}
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
                <Flex
                  ref={dropdownRef}
                  gap="2"
                  py="4"
                  px="2"
                  direction="column"
                  className="absolute right-0 top-full mt-2 w-48 bg-gray-800 rounded-lg shadow-xl py-2 z-50 border border-gray-700"
                >
                  {menu.map((item) => (
                    <NavLink
                      key={item.link}
                      to={item.link}
                      onClick={() => setIsOpen(false)}
                      className={({ isActive, isPending }) =>
                        `block px-4 py-2 -mx-2 hover:bg-gray-700 transition-colors ${
                          isPending
                            ? "text-gray-400"
                            : isActive
                              ? "text-blue-400 font-bold"
                              : "text-gray-200"
                        }`
                      }
                    >
                      <Flex align="center" gap="2">
                        {item.title}
                      </Flex>
                    </NavLink>
                  ))}
                  <Separator
                    size="4"
                    color="gray"
                    className="opacity-70 my-2"
                  />

                  {/* Documentation link in mobile menu */}
                  <a
                    href="https://docs.govex.ai/"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="block px-4 py-2 -mx-2 hover:bg-gray-700 transition-colors text-gray-200"
                    onClick={() => setIsOpen(false)}
                  >
                    <Flex align="center" gap="2">
                      Documentation
                    </Flex>
                  </a>

                  <Separator
                    size="4"
                    color="gray"
                    className="opacity-70 my-2"
                  />

                  {/* Mint in mobile menu - Only on Create page */}
                  {isCreatePage && CONSTANTS.network === "testnet" && <MintTestnetCoins />}

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
