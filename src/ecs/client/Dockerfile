FROM public.ecr.aws/docker/library/node:18

WORKDIR /app

COPY package.json .
RUN npm install

COPY client.js .

CMD ["node", "client.js"]