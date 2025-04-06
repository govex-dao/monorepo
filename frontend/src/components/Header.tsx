import { ConnectButton } from "@mysten/dapp-kit";
import { SizeIcon, HamburgerMenuIcon } from "@radix-ui/react-icons";
import { Box, Container, Flex, IconButton } from "@radix-ui/themes";
import { NavLink } from "react-router-dom";
import { HeaderWithGlowIcon } from "./HeaderWithGlowIcon.tsx";
import { useState, useCallback } from 'react';

const menu = [
  { title: "Trade", link: "/" },
  { title: "Create", link: "/create" },
  { title: "Learn", link: "/learn", icon: <SizeIcon /> },
];

export function Header() {
  const [isOpen, setIsOpen] = useState(false);

  const handleClick = useCallback(() => {
    setIsOpen(!isOpen);
  }, [isOpen]);

  return (
    <Container style={{ maxWidth: '100vw', width: '100vw' }}>
      <Flex
        position="sticky"
        px="4"
        py="2"
        justify="between"
        align="center"
        className="border-b relative"
      >
        <Box className="flex items-center pr-">
          <NavLink to="/">
            <HeaderWithGlowIcon />
          </NavLink>
        </Box>

        {/* Desktop Menu */}
        <Box className="hidden md:flex gap-5 items-center h-full">
          {menu.map((item) => (
            <NavLink
              key={item.link}
              to={item.link}
              className={({ isActive, isPending }) =>
                `h-full flex items-center gap-2 ${
                  isPending
                    ? "pending"
                    : isActive
                      ? "font-bold text-blue-600"
                      : ""
                }`
              }
            >
              {item.title}
            </NavLink>
          ))}
        </Box>

        <Flex gap="3" align="center">
          <Box className="connect-wallet-wrapper flex items-center">
            <div className="bg-gray-800 rounded-lg p-1">
              <ConnectButton className="hover:bg-gray-700 text-gray-100" />
            </div>
          </Box>
          
          {/* Mobile Menu Button - Moved here */}
          <Box className="md:hidden">
            <IconButton 
              className="md:hidden bg-gray-800 rounded-lg hover:bg-gray-700" 
              variant="ghost"
              onClick={handleClick}
            >
              <HamburgerMenuIcon width="24" height="24" className="text-gray-300" />
            </IconButton>

            {/* Dropdown overlay */}
            {isOpen && (
              <div className="absolute right-0 top-full mt-2 w-48 bg-gray-800 rounded-lg shadow-lg py-1 z-50">
                {menu.map((item) => (
                  <NavLink
                    key={item.link}
                    to={item.link}
                    onClick={() => setIsOpen(false)}
                    className={({ isActive, isPending }) =>
                      `block px-4 py-2 hover:bg-gray-700 ${
                        isPending
                          ? "pending"
                          : isActive
                            ? "font-bold text-blue-600"
                            : "text-gray-200"
                      }`
                    }
                  >
                    {item.title}
                  </NavLink>
                ))}
              </div>
            )}
          </Box>
        </Flex>
      </Flex>
    </Container>
  );
}

export default Header;