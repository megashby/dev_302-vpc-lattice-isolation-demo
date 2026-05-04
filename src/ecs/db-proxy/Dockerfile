FROM public.ecr.aws/docker/library/node:18

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install

COPY server.js .

EXPOSE 3000

CMD ["node", "server.js"]