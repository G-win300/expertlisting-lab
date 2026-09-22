FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
# The git SHA is baked into the image so /api/info can prove which build is live.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
