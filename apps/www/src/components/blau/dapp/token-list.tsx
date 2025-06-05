"use client";
import { useState } from "react";

const tokens = [
  {
    id: "eth",
    name: "Ethereum",
    symbol: "ETH",
    price: 11558.52,
    amount: 3.08,
    logo: "/ethereum-logo.png",
  },
  {
    id: "dai",
    name: "Dai",
    symbol: "DAI",
    price: 5021.94,
    amount: 5021.94,
    logo: "/dai-logo.png",
  },
  {
    id: "ape",
    name: "ApeCoin",
    symbol: "APE",
    price: 4107.23,
    amount: 3367,
    logo: "/apecoin-logo.png",
  },
  {
    id: "degen",
    name: "Degen",
    symbol: "DEGEN",
    price: 3521.12,
    amount: 519569.13,
    logo: "/degen-logo.png",
  },
];

export function TokenList() {
  const [sortByPrice, setSortByPrice] = useState(false);

  const handleToggleSort = () => {
    setSortByPrice(!sortByPrice);
  };

  const sortedTokens = sortByPrice
    ? [...tokens].sort((a, b) => b.price - a.price)
    : tokens;

  return (
    <div className="space-y-4">
      {sortedTokens.map((token) => (
        <div key={token.id} className="bg-white rounded-xl p-4 shadow-sm">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className="w-12 h-12 rounded-full overflow-hidden bg-gray-100 flex items-center justify-center">
                {token.logo === "/ethereum-logo.png" && (
                  <div className="w-full h-full bg-blue-400 rounded-full flex items-center justify-center">
                    <svg
                      viewBox="0 0 24 24"
                      fill="none"
                      xmlns="http://www.w3.org/2000/svg"
                      className="w-8 h-8"
                    >
                      <path d="M12 2L5 12L12 16L19 12L12 2Z" fill="white" />
                      <path d="M12 16L5 12L12 22L19 12L12 16Z" fill="white" />
                    </svg>
                  </div>
                )}
                {token.logo === "/dai-logo.png" && (
                  <div className="w-full h-full bg-yellow-400 rounded-full flex items-center justify-center">
                    <svg
                      viewBox="0 0 24 24"
                      fill="none"
                      xmlns="http://www.w3.org/2000/svg"
                      className="w-8 h-8"
                    >
                      <path
                        d="M12 2C6.48 2 2 6.48 2 12C2 17.52 6.48 22 12 22C17.52 22 22 17.52 22 12C22 6.48 17.52 2 12 2ZM12 20C7.59 20 4 16.41 4 12C4 7.59 7.59 4 12 4C16.41 4 20 7.59 20 12C20 16.41 16.41 20 12 20Z"
                        fill="white"
                      />
                      <path
                        d="M8 12H16M12 8V16"
                        stroke="white"
                        strokeWidth="2"
                      />
                    </svg>
                  </div>
                )}
                {token.logo === "/apecoin-logo.png" && (
                  <div className="w-full h-full bg-blue-600 rounded-full flex items-center justify-center">
                    <svg
                      viewBox="0 0 24 24"
                      fill="none"
                      xmlns="http://www.w3.org/2000/svg"
                      className="w-8 h-8"
                    >
                      <circle cx="12" cy="12" r="10" fill="#4169E1" />
                      <path
                        d="M8 9C8 7.34 9.34 6 11 6C12.66 6 14 7.34 14 9C14 10.66 12.66 12 11 12C9.34 12 8 10.66 8 9Z"
                        fill="white"
                      />
                      <path
                        d="M15 9C15 7.34 16.34 6 18 6C19.66 6 21 7.34 21 9C21 10.66 19.66 12 18 12C16.34 12 15 10.66 15 9Z"
                        fill="white"
                      />
                      <path
                        d="M12 14C9.79 14 8 15.79 8 18H16C16 15.79 14.21 14 12 14Z"
                        fill="white"
                      />
                    </svg>
                  </div>
                )}
                {token.logo === "/degen-logo.png" && (
                  <div className="w-full h-full bg-purple-500 rounded-full flex items-center justify-center">
                    <svg
                      viewBox="0 0 24 24"
                      fill="none"
                      xmlns="http://www.w3.org/2000/svg"
                      className="w-8 h-8"
                    >
                      <circle cx="12" cy="12" r="10" fill="#8A2BE2" />
                      <path d="M8 14H16V18H8V14Z" fill="white" />
                      <path d="M10 8H14V12H10V8Z" fill="white" />
                    </svg>
                  </div>
                )}
              </div>
              <div>
                <h2 className="font-bold text-xl">{token.symbol}</h2>
                <p className="text-gray-500">{token.name}</p>
              </div>
            </div>
            <div className="text-right">
              <p className="font-bold text-xl">
                ${token.price.toLocaleString()}
              </p>
              <p className="text-gray-500">
                {token.amount.toLocaleString()} {token.symbol}
              </p>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
